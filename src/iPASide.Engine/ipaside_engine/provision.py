"""Provisioning orchestration.

Turns an authenticated session into everything zsign needs to sign an app for a
specific device on a free (or paid) Apple ID:

1. a development certificate (generate key + CSR, submit, cache),
2. the target device registered to the team,
3. an App ID for the app's bundle identifier,
4. a provisioning profile binding the cert + device + App ID.

The private key never leaves this machine; the resulting PKCS#12 + profile are
cached under the per-user signing directory and reused until they expire (free
profiles last 7 days), so repeat signs don't burn Apple's rate limits.
"""

from __future__ import annotations

import base64
import json
import os
import secrets
import sys
import tempfile
from pathlib import Path
from typing import Any, Callable

from cryptography import x509
from cryptography.hazmat.primitives import serialization

from . import developer, gsa, paths, refresh, secure_store, signing

_CERT_CACHE = "certificate.json"
_BUNDLE_CACHE = "bundle.json"
_IDENTITY_P12 = "identity.p12"
_PROFILE = "profile.mobileprovision"

#: The machine name EZSide registers its certificates under.
#:
#: Load-bearing rather than cosmetic: Apple's per-machine certificate limit is what lets
#: one account hold a certificate for Xcode, another for SideStore, and this one at the
#: same time, so it is also how a re-issue tells ours apart from theirs. Changing it
#: orphans the certificate already issued under the old name. It differs from upstream
#: iPASide's on purpose, so the two apps never revoke each other's certificate.
CERTIFICATE_MACHINE_NAME = "EZSide"


def _account_slug(email: str | None) -> str | None:
    """The per-account signing folder name, or None before anyone has signed in."""
    return paths.account_slug(email) if email else None


def _read_secret(path: Path) -> dict[str, Any] | None:
    """Read certificate.json / bundle.json; None when it is missing or its content is unusable.

    Unusable most often means DPAPI refuses it: the data folder was copied to another
    PC or Windows user. That is treated as no file at all - with one line saying so -
    so the next sideload issues new assets instead of every sideload failing for good.

    Failing to read the file at all (a backup or indexer tool holding it open, no
    access) is not "no file": it raises, because a caller that took it for one would
    revoke a certificate that is still good.
    """
    if not path.exists():
        return None
    raw = path.read_bytes()
    try:
        data = json.loads(secure_store.unwrap(raw).decode("utf-8"))
    except (OSError, ValueError) as exc:
        _note(f"Ignoring {path.name}, which cannot be read on this PC or account ({exc}).")
        return None
    if not isinstance(data, dict):
        _note(f"Ignoring {path.name}, which is damaged.")
        return None
    return data


def _note(message: str) -> None:
    """One line on the engine's progress channel (stderr; serve forwards it)."""
    event = {"event": "progress", "phase": "provision", "percent": None, "step": message}
    print(json.dumps(event), file=sys.stderr, flush=True)


def _write_atomic(path: Path, data: bytes) -> None:
    """Write [data] to a temp file beside [path], then swap it in with one rename."""
    fd, temp = tempfile.mkstemp(dir=path.parent, prefix=f"{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
        secure_store.replace_atomic(temp, path)
    except BaseException:
        Path(temp).unlink(missing_ok=True)
        raise


def cached_serial(email: str | None) -> str | None:
    """Serial of the certificate EZSide holds for [email]; None when there is none.

    Local state only, no Apple call: what a refresh compares each app's ``cert_serial``
    with to find apps signed by a certificate that has since been replaced.
    """
    if not email:
        return None
    # Not signing_dir(): that creates the folder, and a read should leave none behind.
    path = paths.data_dir() / "signing" / paths.account_slug(email) / _CERT_CACHE
    try:
        data = secure_store.read_json(path) if path.exists() else None
    except (OSError, ValueError):
        return None
    serial = data.get("serial") if isinstance(data, dict) else None
    return serial or None


def load_bundle() -> dict[str, Any]:
    """Return the cached signing bundle from a prior `provision`, or raise.

    Scoped to the active account: a bundle provisioned by a different Apple ID
    names an App ID on a team this session cannot see, and signing with it fails
    in a way that looks like a bug in signing rather than a stale cache.

    Never rewrites the file: that happens only in :func:`ensure_signing_assets`,
    under the engine lock.
    """
    session = gsa.load_session()
    bundle = _read_secret(paths.signing_dir(_account_slug(session.get("email"))) / _BUNDLE_CACHE)
    if bundle is None:
        raise gsa.GsaError("no signing bundle; run 'provision' first")
    return bundle


def team_scoped_bundle_id(base_bundle_id: str) -> str:
    """Return a bundle id guaranteed registerable on a free account.

    A free Apple ID cannot register a real App Store app's identifier (Apple
    returns error 9401 "not available"). Appending the team id makes it unique
    and always registerable, which is why every free-account signing flow does it.
    """
    team_id = developer.list_teams()[0]["teamId"]
    if base_bundle_id.lower().endswith("." + team_id.lower()):
        return base_bundle_id
    return f"{base_bundle_id}.{team_id}"


def _normalize_udid(udid: str) -> str:
    return udid.replace("-", "").lower()


def _cert_content(cert: dict[str, Any]) -> bytes | None:
    """Pull the DER certificate bytes out of a portal cert dict (varied shapes)."""
    for key in ("certContent", "certificateContent", "certificate"):
        value = cert.get(key)
        if isinstance(value, (bytes, bytearray)):
            return bytes(value)
        if isinstance(value, dict):
            inner = value.get("certContent") or value.get("certificateContent")
            if isinstance(inner, (bytes, bytearray)):
                return bytes(inner)
    return None


def _public_key_der(obj: Any) -> bytes:
    return obj.public_key().public_bytes(
        serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo
    )


def _find_cert_for_key(certs: list[dict[str, Any]], key_pem: bytes) -> tuple[bytes | None, str | None]:
    """Return (der, serial) for the certificate matching our private key's public key."""
    my_public = _public_key_der(serialization.load_pem_private_key(key_pem, password=None))
    for cert in certs:
        content = _cert_content(cert)
        if not content:
            continue
        try:
            parsed = x509.load_der_x509_certificate(content)
        except ValueError:
            continue
        if _public_key_der(parsed) == my_public:
            return content, cert.get("serialNumber")
    return None, None


def _is_certificate_limit(exc: Exception) -> bool:
    """True for Apple's "you already have a current certificate" refusal (error 7460)."""
    text = str(exc)
    return text.startswith("7460") or "already have a current" in text.lower()


def _foreign_certificate_names(certs: list[dict[str, Any]]) -> list[str]:
    """The machine names of the certificates on the team that EZSide did not create."""
    names: list[str] = []
    for cert in certs:
        if cert.get("machineName") == CERTIFICATE_MACHINE_NAME:
            continue
        name = str(cert.get("machineName") or "").strip() or "an unnamed certificate"
        if name not in names:
            names.append(name)
    return names


def _ensure_certificate(
    team_id: str, account_slug: str | None
) -> tuple[bytes, bytes, str, str]:
    """Return (private_key_pem, certificate_der, serial, p12_password), creating one if needed.

    The key cache is per account. Shared, a second Apple ID would find the first
    one's key, fail to match it against its own team's certificates, and respond by
    revoking a certificate — breaking every app that had signed.

    The identity.p12 password is made once per certificate issued and kept with it, so
    rebuilding the .p12 for the same certificate never changes it. A legacy cache (plain
    text, or from before the password lived here) is rewritten protected, with one.

    Re-issuing only ever revokes a certificate iPASide itself registered; see
    :data:`CERTIFICATE_MACHINE_NAME`.
    """
    cache_path = paths.signing_dir(account_slug) / _CERT_CACHE
    server_certs = developer.list_certificates(team_id)
    cached = _read_secret(cache_path)
    if cached is not None:
        serial = cached.get("serial")
        if any(c.get("serialNumber") == serial for c in server_certs):
            password = cached.get("p12_password")
            if not password or not cache_path.read_bytes().startswith(secure_store.MAGIC):
                password = password or secrets.token_urlsafe(24)
                secure_store.write_json(cache_path, {**cached, "p12_password": password})
            return (
                base64.b64decode(cached["key_pem"]),
                base64.b64decode(cached["cert_der"]),
                serial,
                password,
            )

    # We need to issue a new certificate, and the account has limited room for them, so
    # an old one has to go. Only ever one of *ours*: Apple scopes the limit per machine
    # rather than per account, so the same team routinely holds a certificate for Xcode
    # on a Mac and another for SideStore on the phone, and both coexist with this one -
    # verified on a free account holding all three at once. Revoking those would stop
    # every app they signed from launching, in tools iPASide has nothing to do with.
    revoke_failure: Exception | None = None
    for cert in server_certs:
        serial = cert.get("serialNumber")
        if serial and cert.get("machineName") == CERTIFICATE_MACHINE_NAME:
            try:
                developer.revoke_certificate(team_id, serial)
            except developer.DeveloperServicesError as exc:
                # Not fatal on its own - the certificate may already be gone, and the
                # request below is the real test of whether there was room. Remembered
                # rather than swallowed, so it can explain a failure that follows.
                revoke_failure = exc

    key_pem, csr_pem = signing.generate_key_and_csr()
    try:
        developer.submit_csr(team_id, csr_pem, machine_name=CERTIFICATE_MACHINE_NAME)
    except developer.DeveloperServicesError as exc:
        if revoke_failure is not None:
            raise gsa.GsaError(
                f"Apple would not issue a signing certificate ({exc}), and the old "
                f"EZSide certificate could not be revoked to make room for it "
                f"({revoke_failure}). Revoking it in the Apple Developer portal, under "
                "Certificates, will let this succeed."
            ) from exc
        others = _foreign_certificate_names(server_certs)
        if _is_certificate_limit(exc) and others:
            # Apple's limit is full of certificates that belong to other tools. Say so, and say
            # what the way out costs, instead of repeating Apple's sentence about "a current
            # certificate", which reads as if EZSide had made one.
            raise gsa.GsaError(
                f"Apple would not issue a signing certificate for EZSide ({exc}). This Apple ID "
                f"already holds development certificates that other tools made "
                f"({', '.join(others)}). EZSide never revokes a certificate it did not create, "
                "because that stops every app the certificate signed from opening. To continue, "
                "open the Account page, revoke one of them (the apps it signed stop opening "
                "until the tool that made it signs them again), then try again."
            ) from exc
        raise
    # Match the freshly-issued certificate to our key by public key (robust: the
    # CSR response's serial does not always line up with the listed serial).
    cert_der, serial = _find_cert_for_key(developer.list_certificates(team_id), key_pem)
    if cert_der is None:
        raise gsa.GsaError("could not obtain certificate content from Apple")

    password = secrets.token_urlsafe(24)
    secure_store.write_json(
        cache_path,
        {
            "serial": serial,
            "key_pem": base64.b64encode(key_pem).decode(),
            "cert_der": base64.b64encode(cert_der).decode(),
            "p12_password": password,
        },
    )
    return key_pem, cert_der, serial, password


def _ensure_device(team_id: str, udid: str, name: str) -> None:
    target = _normalize_udid(udid)
    for existing in developer.list_devices(team_id):
        if _normalize_udid(existing.get("deviceNumber", "")) == target:
            return
    try:
        developer.register_device(team_id, udid, name)
    except developer.DeveloperServicesError as exc:
        if "already exist" not in str(exc).lower():
            raise


def _ensure_app_id(team_id: str, bundle_id: str, name: str) -> dict[str, Any]:
    for existing in developer.list_app_ids(team_id):
        if existing.get("identifier") == bundle_id:
            return existing
    try:
        return developer.add_app_id(team_id, bundle_id, name)
    except developer.DeveloperServicesError:
        for existing in developer.list_app_ids(team_id):
            if existing.get("identifier") == bundle_id:
                return existing
        raise


def _ensure_app_groups(
    team_id: str,
    app_id: dict[str, Any],
    app_id_id: str,
    identifiers: list[str],
    name: str,
) -> list[str]:
    """Attach app groups to an App ID so the profile grants them; return their ids.

    Two steps in a specific order, both required: the app-groups capability has to be
    enabled on the App ID before a group can be assigned to it, and the profile has to
    be downloaded afterwards to pick the assignment up. Free accounts are allowed all
    of this - verified against one.
    """
    if not app_id.get("features", {}).get(developer.FEATURE_APP_GROUPS):
        developer.enable_app_id_feature(team_id, app_id_id, developer.FEATURE_APP_GROUPS)

    existing = {
        group.get("identifier"): group for group in developer.list_application_groups(team_id)
    }
    group_ids: list[str] = []
    for identifier in identifiers:
        group = existing.get(identifier)
        if group is None:
            group = developer.add_application_group(team_id, identifier, name)
        internal_id = group.get("applicationGroup")
        if not internal_id:
            raise gsa.GsaError(f"app group {identifier} has no id to assign")
        group_ids.append(internal_id)

    developer.assign_application_groups(team_id, app_id_id, group_ids)
    return group_ids


@refresh.operation_lock()
def ensure_signing_assets(
    bundle_id: str,
    udid: str,
    app_name: str = "EZSide App",
    device_name: str = "EZSide device",
    on_step: Callable[[str], None] | None = None,
    app_groups: list[str] | None = None,
) -> dict[str, Any]:
    """Provision cert + device + App ID + profile and cache a signing bundle.

    ``app_groups`` names ``group.…`` identifiers to attach to the App ID. Ordinary
    sideloads do not need any; LiveContainer does, because a shared container is how
    it reaches the certificate it signs guest apps with.

    Runs under :func:`refresh.operation_lock`: it writes the signing folder, which the
    other engine process may be signing from.
    """
    step = on_step or (lambda _m: None)
    step("Contacting Apple\u2026")
    session = gsa.load_session()  # raises if not signed in
    account = session.get("email")
    team = developer.list_teams()[0]
    team_id = team["teamId"]
    # Remember which team this Apple ID provisions under, so a later refresh can
    # find its way back to the right account instead of using whichever is active.
    if account:
        gsa.remember_team(account, team_id)

    step("Preparing signing certificate\u2026")
    key_pem, cert_der, serial, p12_password = _ensure_certificate(team_id, _account_slug(account))
    step("Registering your device\u2026")
    _ensure_device(team_id, udid, device_name)
    step("Creating the App ID\u2026")
    app_id = _ensure_app_id(team_id, bundle_id, app_name)
    app_id_id = app_id.get("appIdId") or app_id.get("appIdPlatform") or app_id.get("identifier")

    group_ids: list[str] = []
    if app_groups:
        step("Attaching app groups\u2026")
        group_ids = _ensure_app_groups(team_id, app_id, app_id_id, app_groups, app_name)

    step("Fetching the provisioning profile\u2026")
    profile = developer.download_profile(team_id, app_id_id)
    profile_data = profile.get("encodedProfile")
    if not isinstance(profile_data, (bytes, bytearray)):
        raise gsa.GsaError("provisioning profile download did not return profile data")

    signing_dir = paths.signing_dir(_account_slug(account))
    p12_path = signing_dir / _IDENTITY_P12
    profile_path = signing_dir / _PROFILE
    # The certificate's own password (see _ensure_certificate), kept only in the protected
    # JSON files; the .p12 itself stays a plain PKCS#12 because zsign reads it. Each file
    # is swapped in whole, the .p12 before the bundle.json that names its password.
    _write_atomic(p12_path, signing.build_p12(cert_der, key_pem, p12_password))
    _write_atomic(profile_path, bytes(profile_data))

    bundle = {
        "team_id": team_id,
        "team_name": team.get("name"),
        "account": account,
        "bundle_id": bundle_id,
        "app_id_id": app_id_id,
        "certificate_serial": serial,
        "udid": udid,
        "p12_path": str(p12_path),
        "p12_password": p12_password,
        "profile_path": str(profile_path),
        "app_groups": app_groups or [],
        "app_group_ids": group_ids,
    }
    secure_store.write_json(signing_dir / _BUNDLE_CACHE, bundle)
    return bundle
