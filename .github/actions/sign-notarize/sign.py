"""Sign an assembled app and staple its notarization ticket in an isolated runner."""
import base64
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shlex
import subprocess
import sys
import tempfile


def main():
    if (os.environ.get("GITHUB_ACTIONS") != "true"
            or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted"
            or os.environ.get("RUNNER_OS") != "macOS"):
        raise ValueError("Signing requires a disposable GitHub-hosted macOS runner.")
    required = ["SIGNING_APP", "RUNNER_TEMP", "APPLE_CERTIFICATE", "APPLE_CERTIFICATE_PASSWORD",
                "APPLE_SIGNING_IDENTITY", "APPLE_TEAM_ID", "APPLE_ID", "APPLE_PASSWORD"]
    for name in required:
        if not os.environ.get(name):
            raise ValueError(f"Missing required input: {name}")
    app = Path(os.environ["SIGNING_APP"]).resolve()
    if app.suffix != ".app" or not app.is_dir():
        raise ValueError("SIGNING_APP must be an assembled .app directory.")
    identity, team = os.environ["APPLE_SIGNING_IDENTITY"], os.environ["APPLE_TEAM_ID"]
    if not identity.startswith("Developer ID Application:") or not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise ValueError("A Developer ID Application identity and ten-character Team ID are required.")
    keychain_password = secrets.token_urlsafe(32)
    sensitive = [os.environ[name] for name in required if name.startswith("APPLE_")] + [keychain_password]

    def safe(text):
        for value in sensitive:
            text = text.replace(value, "***")
        return text

    def run(*args, check=True):
        result = subprocess.run(args, capture_output=True, text=True)
        if check and result.returncode:
            print(safe(result.stdout + result.stderr)[:8000], file=sys.stderr)
            raise RuntimeError(f"{Path(args[0]).name} failed with exit code {result.returncode}.")
        return result

    original_keychains = shlex.split(run("security", "list-keychains", "-d", "user").stdout)
    with tempfile.TemporaryDirectory(prefix="apple-signing-", dir=os.environ["RUNNER_TEMP"]) as folder:
        temporary = Path(folder)
        keychain = str(temporary / "signing.keychain-db")
        certificate = temporary / "identity.p12"
        certificate.write_bytes(base64.b64decode(os.environ["APPLE_CERTIFICATE"]))
        certificate.chmod(0o600)
        try:
            run("security", "create-keychain", "-p", keychain_password, keychain)
            run("security", "set-keychain-settings", "-lut", "21600", keychain)
            run("security", "unlock-keychain", "-p", keychain_password, keychain)
            run("security", "import", str(certificate), "-P", os.environ["APPLE_CERTIFICATE_PASSWORD"],
                "-k", keychain, "-T", "/usr/bin/codesign")
            certificate.unlink()
            run("security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s",
                "-k", keychain_password, keychain)
            run("security", "list-keychains", "-d", "user", "-s", keychain, *original_keychains)
            signing = ["codesign", "--force", "--sign", identity, "--keychain", keychain,
                       "--options", "runtime", "--timestamp"]
            if os.environ.get("SIGNING_ENTITLEMENTS"):
                entitlements = Path(os.environ["SIGNING_ENTITLEMENTS"]).resolve(strict=True)
                signing += ["--entitlements", str(entitlements)]
            run(*signing, str(app))
            run("codesign", "--verify", "--deep", "--strict", "--all-architectures", str(app))
            info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            binary = app / "Contents/MacOS" / info["CFBundleExecutable"]
            for arch in run("lipo", "-archs", str(binary)).stdout.split():
                signature = run("codesign", "--display", "--verbose=4", "--architecture", arch, str(app)).stderr
                if (f"TeamIdentifier={team}" not in signature or "(runtime)" not in signature
                        or "Authority=Developer ID Application:" not in signature or "Timestamp=" not in signature):
                    raise ValueError(f"Unexpected signing identity, runtime or timestamp for {arch}.")
            print("Developer ID signature, Team ID, hardened runtime and timestamp verified.", flush=True)
            profile = "release-notarization"
            run("xcrun", "notarytool", "store-credentials", profile, "--keychain", keychain,
                "--apple-id", os.environ["APPLE_ID"], "--team-id", team, "--password", os.environ["APPLE_PASSWORD"])
            payload = temporary / "submission.zip"
            run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(payload))
            auth = ["--keychain-profile", profile, "--keychain", keychain]
            print("Submitting to Apple's notary service; waiting up to 20 minutes.", flush=True)
            result = run("xcrun", "notarytool", "submit", str(payload), *auth,
                         "--wait", "--timeout", "20m", "--output-format", "json", check=False)
            try:
                receipt = json.loads(result.stdout)
            except json.JSONDecodeError:
                print(safe(result.stdout + result.stderr)[:8000], file=sys.stderr)
                raise RuntimeError("Notary service did not return a JSON receipt.") from None
            submission = receipt.get("id", "")
            print(f"Notarization submission: {submission}; status: {receipt.get('status', 'unknown')}", flush=True)
            if result.returncode or receipt.get("status") != "Accepted":
                if submission:
                    log_path = temporary / "notary-log.json"
                    run("xcrun", "notarytool", "log", submission, *auth, str(log_path), check=False)
                    if log_path.exists():
                        print(safe(log_path.read_text())[:16000], file=sys.stderr)
                raise RuntimeError("Notarization was not accepted; no release will be created.")
            run("xcrun", "stapler", "staple", str(app))
            run("xcrun", "stapler", "validate", str(app))
            assessment = run("spctl", "--assess", "--type", "execute", "--verbose=2", str(app))
            print(safe(assessment.stdout + assessment.stderr), flush=True)
            if os.environ.get("GITHUB_OUTPUT"):
                with open(os.environ["GITHUB_OUTPUT"], "a") as output:
                    output.write(f"submission-id={submission}\n")
            print("Notarization ticket stapled and Gatekeeper assessment passed.", flush=True)
        finally:
            run("security", "list-keychains", "-d", "user", "-s", *original_keychains, check=False)
            run("security", "delete-keychain", keychain, check=False)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, OSError) as error:
        print(f"Signing failed: {error}", file=sys.stderr)
        sys.exit(1)
