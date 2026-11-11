"""Signing-material crypto helpers.

Generates the RSA keypair + PKCS#10 CSR sent to Apple to obtain a development
certificate, and assembles the resulting certificate plus the (locally-held)
private key into a PKCS#12 bundle that zsign consumes at sign time. Apple never
sees the private key; it lives only on this machine.
"""

from __future__ import annotations

import os
import secrets
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

from cryptography import x509
from cryptography.exceptions import UnsupportedAlgorithm
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.x509.oid import NameOID

from . import paths
from .errors import EngineError

P12_PASSWORD = "iPASide"


class SigningError(EngineError):
    """Raised when zsign fails to sign an IPA."""


def generate_key_and_csr(common_name: str = "iPASide") -> tuple[bytes, str]:
    """Return (private_key_pem, csr_pem) for a fresh RSA-2048 development key."""
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    csr = (
        x509.CertificateSigningRequestBuilder()
        .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, common_name)]))
        .sign(key, hashes.SHA256())
    )
    key_pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.TraditionalOpenSSL,
        serialization.NoEncryption(),
    )
    csr_pem = csr.public_bytes(serialization.Encoding.PEM).decode()
    return key_pem, csr_pem


def build_p12(cert_der: bytes, key_pem: bytes, password: str = P12_PASSWORD) -> bytes:
    """Bundle a DER certificate + PEM private key into a PKCS#12 blob for zsign."""
    key = serialization.load_pem_private_key(key_pem, password=None)
    cert = x509.load_der_x509_certificate(cert_der)
    encryption = (
        serialization.BestAvailableEncryption(password.encode())
        if password
        else serialization.NoEncryption()
    )
    return pkcs12.serialize_key_and_certificates(b"EZSide", key, cert, None, encryption)


def resolve_zsign() -> str:
    """Locate the zsign binary: env override, bundled vendor copy, then PATH."""
    override = os.environ.get("IPASIDE_ZSIGN")
    if override and Path(override).exists():
        return override
    exe = "zsign.exe" if os.name == "nt" else "zsign"
    candidates = [
        paths.resource_dir() / "vendor" / exe,   # bundled next to the package (frozen or source)
        Path(sys.executable).parent / exe,        # alongside a frozen engine exe
    ]
    for candidate in candidates:
        if candidate.exists():
            return str(candidate)
    found = shutil.which("zsign")
    if found:
        return found
    raise SigningError("zsign not found (set IPASIDE_ZSIGN or bundle vendor/zsign.exe)")


#: Injected into LiveContainer so it can import our signing certificate itself.
HELPER_DYLIB = "iPASideCertImport.dylib"


def resolve_helper_dylib() -> str | None:
    """Locate the bundled certificate-import dylib, or None if it is not shipped.

    This is an iOS arm64 Mach-O, so it is built on macOS in CI and committed rather
    than compiled during packaging (see tools/lc-cert-import/). Callers treat a
    missing dylib as "fall back to a manual import" rather than an error, so a build
    that omits it still installs LiveContainer successfully.
    """
    override = os.environ.get("IPASIDE_CERT_IMPORT_DYLIB")
    if override and Path(override).exists():
        return override
    candidates = [
        paths.resource_dir() / "vendor" / HELPER_DYLIB,
        Path(sys.executable).parent / HELPER_DYLIB,
    ]
    for candidate in candidates:
        if candidate.exists():
            return str(candidate)
    return None


_TEMP_DIR_NAME = "signing-temp"


def _discard(path: Path) -> None:
    """Delete a file or folder; a failure is a warning (no secrets) and the next sign retries."""
    try:
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path)
        else:
            path.unlink()
    except FileNotFoundError:
        pass
    except OSError as exc:
        print(f"signing: could not delete a temporary signing file ({type(exc).__name__})",
              file=sys.stderr, flush=True)


def sweep_signing_temp() -> None:
    """Delete every leftover temporary identity from the signing-temp folder.

    The engine can be killed mid-sign (closing the app force-kills it), which skips the
    cleanup in ``sign_ipa``. Called before each sign and from ``custom_cert.remove()``; run it
    under the operation lock so it never deletes the copy of a sign that is running.
    """
    try:
        entries = list((paths.data_dir() / _TEMP_DIR_NAME).iterdir())
    except OSError:  # no folder yet: nothing to sweep
        return
    for entry in entries:
        _discard(entry)


def _ephemeral_p12(p12_path: str, password: str, folder: Path) -> tuple[str, str]:
    """Re-export an identity into ``folder`` under a one-time password, for zsign's argv.

    A command line is readable by other processes, so the long-lived password that
    protects the stored identity must never be passed there. The one-time password
    guards only a short-lived copy that the caller deletes as soon as zsign exits.
    """
    path = Path(p12_path)
    if not path.is_file():
        raise SigningError("The signing certificate file is missing; sign in again or re-import the certificate.")
    data = path.read_bytes()
    loaded = None
    for secret in ([password.encode()] if password else [b"", None]):  # "" may mean a p12 made without one
        try:
            loaded = pkcs12.load_key_and_certificates(data, secret)
            break
        except (ValueError, UnsupportedAlgorithm):
            continue
    if loaded is None or loaded[0] is None or loaded[1] is None:
        raise SigningError("The signing identity could not be read: wrong password or damaged .p12 file.")
    key, cert, others = loaded
    one_time = secrets.token_urlsafe(24)
    blob = pkcs12.serialize_key_and_certificates(
        b"EZSide", key, cert, others or None, serialization.BestAvailableEncryption(one_time.encode())
    )
    target = folder / "identity.p12"
    target.write_bytes(blob)
    return str(target), one_time


def sign_ipa(
    input_ipa: str,
    output_ipa: str,
    *,
    p12_path: str,
    p12_password: str,
    profile_path: str,
    bundle_id: str | None = None,
    display_name: str | None = None,
    bundle_version: str | None = None,
    remove_extensions: bool = True,
    remove_watch: bool = True,
    remove_uisd: bool = True,
    enable_file_sharing: bool = False,
    dylibs: list[str] | None = None,
    weak_dylibs: bool = False,
    inject_into_extensions: bool = False,
    entitlements: str | None = None,
    zip_level: int = 6,
    temp_folder: str | None = None,
    legacy_sha1: bool = False,
) -> dict[str, Any]:
    """Re-sign an IPA with zsign (modern SHA256-only CodeDirectory + DER entitlements).

    ``legacy_sha1`` adds a SHA-1 CodeDirectory next to the SHA-256 one (zsign ``-L``). iOS 10
    and earlier only understand SHA-1 and refuse a SHA-256-only signature with
    ``ApplicationVerificationFailed``; newer iOS accepts either, so this is for those old
    devices only (see ``sideload._needs_legacy_signature``).

    Options map to zsign flags and cover the "advanced" sideload knobs: bundle
    id/name/version overrides, tweak (dylib) injection (optionally weak / into
    extensions), file-sharing enablement, and the free-account strip flags.

    ``entitlements`` replaces the profile's entitlements with an explicit plist.
    Normally the profile's are exactly right and this should be left alone; it exists
    for apps that need entries a profile does not spell out, such as LiveContainer's
    128 expanded keychain groups. Every entitlement in the file must be covered by the
    profile, or the signature is rejected outright rather than partly granted.

    ``temp_folder`` is where zsign unpacks the IPA and assembles the signed copy -
    by far the heaviest I/O of a sideload, since the whole app is written out and
    re-zipped. Omitted, zsign uses the system temp directory. It must already
    exist: zsign rejects a missing temp folder outright.
    """
    zsign = resolve_zsign()
    cmd = [
        zsign,
        "-m", profile_path,
        "-z", str(zip_level),
        "-o", output_ipa,
    ]
    if temp_folder:
        cmd += ["-t", temp_folder]
    if legacy_sha1:
        cmd.append("-L")
    if bundle_id:
        cmd += ["-b", bundle_id]
    if display_name:
        cmd += ["-n", display_name]
    if bundle_version:
        cmd += ["-r", bundle_version]
    if remove_extensions:
        cmd.append("-E")
    if remove_watch:
        cmd.append("-W")
    if remove_uisd:
        cmd.append("-U")
    if enable_file_sharing:
        cmd.append("-S")
    if entitlements:
        cmd += ["-e", entitlements]
    for dylib in dylibs or []:
        cmd += ["-l", dylib]
    if dylibs and weak_dylibs:
        cmd.append("-w")
    if dylibs and inject_into_extensions:
        cmd.append("-P")
    cmd.append(input_ipa)

    # zsign gets a throwaway copy of the identity (see _ephemeral_p12), in its own subfolder
    # of data_dir()/signing-temp (user-private). A killed engine skips the finally below, so
    # every sign first sweeps what an earlier killed run left behind.
    sweep_signing_temp()
    folder = paths.data_dir() / _TEMP_DIR_NAME
    folder.mkdir(parents=True, exist_ok=True)
    ephemeral = Path(tempfile.mkdtemp(prefix="p12-", dir=folder))
    try:
        key_path, key_password = _ephemeral_p12(p12_path, p12_password, ephemeral)
        cmd[1:1] = ["-k", key_path, "-p", key_password]
        proc = subprocess.run(cmd, capture_output=True, text=True)
    finally:
        _discard(ephemeral)
    if proc.returncode != 0:
        raise SigningError(
            f"zsign failed (exit {proc.returncode}):\n{proc.stdout}\n{proc.stderr}"
        )
    return {"output": output_ipa, "log": proc.stdout}
