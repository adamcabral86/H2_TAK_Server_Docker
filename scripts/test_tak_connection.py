#!/usr/bin/env python3
"""Connection test: mTLS into TAK Server's CoT input, send one test CoT event.

Verifies a service account (gateway-svc.p12 + ca.pem, see
deploy/docker/README.md's "Service/API account for programmatic access")
can actually authenticate to TAK Server and push CoT, without writing any
of the real gateway/reconciliation code yet. Publishes a single point at
lat/lon 0,0 ("Null Island") by default so it's easy to spot on the map and
easy to tell apart from real traffic.

Requires: the `cryptography` package (`pip install cryptography`) - the
stdlib `ssl` module can't load a PKCS12 (.p12) file directly, so this
extracts the cert+key from it in memory and hands `ssl` plain PEM instead.

Usage:
    python3 test_tak_connection.py
    python3 test_tak_connection.py --host devtakserver.h2tak.ca --lat 0 --lon 0
    python3 test_tak_connection.py --p12 /path/to/gateway-svc.p12 --ca /path/to/ca.pem

By default, looks for gateway-svc.p12 and ca.pem in the same directory as
this script (per the instructions you were given when the cert was cut) -
pass --p12/--ca explicitly if you put them somewhere else.
"""
from __future__ import annotations  # lets `tuple[bytes, bytes]` etc. below work on Python < 3.9

import argparse
import getpass
import socket
import ssl
import sys
import tempfile
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

try:
    from cryptography.hazmat.primitives.serialization import (
        Encoding,
        NoEncryption,
        PrivateFormat,
        pkcs12,
    )
except ImportError:
    print("ERROR: this script needs the 'cryptography' package.", file=sys.stderr)
    print("  pip install cryptography", file=sys.stderr)
    sys.exit(1)

SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_HOST = "devtakserver.h2tak.ca"
DEFAULT_PORT = 8089  # TAK Server's TLS CoT input (stdssl) - see deploy/docker/env.example


def load_client_identity(p12_path: Path, password: bytes) -> tuple[bytes, bytes]:
    """Extract (cert_chain_pem, key_pem) from a .p12 - ssl.SSLContext wants
    plain PEM files, not PKCS12, so this is the only reason `cryptography`
    is a dependency here."""
    private_key, certificate, additional_certs = pkcs12.load_key_and_certificates(
        p12_path.read_bytes(), password
    )
    if private_key is None or certificate is None:
        raise ValueError(f"{p12_path} did not contain both a certificate and a private key")

    key_pem = private_key.private_bytes(
        Encoding.PEM, PrivateFormat.TraditionalOpenSSL, NoEncryption()
    )
    # Leaf first, then whatever else the .p12 bundled (makeCert.sh embeds the
    # signing CA via -CAfile when it builds this .p12) - harmless to include,
    # and some TLS stacks want the full chain from load_cert_chain() anyway.
    cert_pem = certificate.public_bytes(Encoding.PEM)
    for extra in additional_certs or []:
        cert_pem += extra.public_bytes(Encoding.PEM)

    return cert_pem, key_pem


def build_ssl_context(ca_path: Path, cert_pem: bytes, key_pem: bytes) -> ssl.SSLContext:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.load_verify_locations(cafile=str(ca_path))

    # ssl.SSLContext.load_cert_chain() only accepts file paths, not in-memory
    # PEM bytes - write to a private temp dir for the life of the connection.
    tmpdir = tempfile.mkdtemp(prefix="tak-conn-test-")
    cert_file = Path(tmpdir) / "client.pem"
    key_file = Path(tmpdir) / "client.key"
    cert_file.write_bytes(cert_pem)
    key_file.write_bytes(key_pem)
    try:
        key_file.chmod(0o600)
    except OSError:
        pass  # best-effort; not fatal on platforms where this doesn't apply (e.g. Windows)
    context.load_cert_chain(certfile=str(cert_file), keyfile=str(key_file))

    # TAK Server's own cert (takserver.jks) is issued with the server's
    # internal CN/SAN (CERT_SERVER_CN in .env, default "takserver") - not
    # the public hostname you actually dial (devtakserver.h2tak.ca), so
    # hostname verification would always fail here even against a perfectly
    # legitimate server. This is exactly how ATAK/WinTAK connect too: they
    # trust the imported CA, they don't check hostname-vs-CN. Chain-of-trust
    # verification against ca.pem stays fully enforced below - this only
    # turns off the one check that's meaningless for TAK's cert model.
    context.check_hostname = False
    context.verify_mode = ssl.CERT_REQUIRED
    return context


def build_test_cot(lat: float, lon: float, uid: str, callsign: str, stale_minutes: int) -> str:
    now = datetime.now(timezone.utc)
    stale = now + timedelta(minutes=stale_minutes)
    fmt = "%Y-%m-%dT%H:%M:%SZ"
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        f'<event version="2.0" uid="{uid}" type="a-f-G" '
        f'time="{now.strftime(fmt)}" start="{now.strftime(fmt)}" stale="{stale.strftime(fmt)}" '
        'how="m-g">'
        f'<point lat="{lat}" lon="{lon}" hae="0.0" ce="9999999.0" le="9999999.0"/>'
        '<detail>'
        f'<contact callsign="{callsign}"/>'
        '<remarks>TAK connection test - sent by test_tak_connection.py</remarks>'
        '</detail>'
        '</event>'
    )


def send_cot(host: str, port: int, context: ssl.SSLContext, cot_xml: str, read_timeout: float) -> None:
    print(f"Connecting to {host}:{port} (TLS)...")
    with socket.create_connection((host, port), timeout=10) as raw_sock:
        with context.wrap_socket(raw_sock, server_hostname=host) as tls_sock:
            cert = tls_sock.getpeercert()
            print(f"TLS handshake OK - {tls_sock.version()}, cipher={tls_sock.cipher()[0]}")
            if cert:
                subject = dict(x[0] for x in cert.get("subject", []))
                print(f"Server cert subject: {subject}")
            else:
                # getpeercert() returns {} (not None) when check_hostname is
                # off unless you also request the binary form - absence of
                # parsed fields here doesn't mean the chain wasn't validated;
                # load_verify_locations + CERT_REQUIRED above already did that.
                print("Server cert presented and verified against ca.pem (fields not decoded).")

            print(f"Sending test CoT:\n{cot_xml}\n")
            tls_sock.sendall(cot_xml.encode("utf-8"))

            tls_sock.settimeout(read_timeout)
            try:
                data = tls_sock.recv(4096)
                if data:
                    print(f"Server sent {len(data)} bytes back (connection is live both ways):")
                    print(data[:500])
                else:
                    print("Connection closed by server after send (no data returned).")
            except socket.timeout:
                print(
                    f"No data received within {read_timeout}s - normal for a plain publish "
                    "(TAK doesn't ack a CoT submission); the send above completing without "
                    "error is what confirms it went through."
                )
    print("Done. Check WebTAK/ATAK for a marker near Null Island (0, 0) if lat/lon were left at defaults.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default=DEFAULT_HOST, help=f"TAK Server host (default: {DEFAULT_HOST})")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help=f"TLS CoT port (default: {DEFAULT_PORT})")
    parser.add_argument("--p12", type=Path, default=SCRIPT_DIR / "gateway-svc.p12", help="Path to the client .p12 (default: gateway-svc.p12 next to this script)")
    parser.add_argument("--ca", type=Path, default=SCRIPT_DIR / "ca.pem", help="Path to the root CA cert (default: ca.pem next to this script)")
    parser.add_argument("--password", default=None, help="Password for the .p12 (default: prompt; matches CERT_PASS in .env)")
    parser.add_argument("--lat", type=float, default=0.0, help="Test point latitude (default: 0.0)")
    parser.add_argument("--lon", type=float, default=0.0, help="Test point longitude (default: 0.0)")
    parser.add_argument("--uid", default=None, help="CoT event uid (default: a fresh test-<uuid>)")
    parser.add_argument("--callsign", default="CONN-TEST", help="Marker callsign shown on the map (default: CONN-TEST)")
    parser.add_argument("--stale-minutes", type=int, default=10, help="Minutes before the point goes stale (default: 10)")
    parser.add_argument("--read-timeout", type=float, default=3.0, help="Seconds to wait for any reply after sending (default: 3.0)")
    args = parser.parse_args()

    if not args.p12.is_file():
        print(f"ERROR: client cert not found: {args.p12}", file=sys.stderr)
        sys.exit(1)
    if not args.ca.is_file():
        print(f"ERROR: CA cert not found: {args.ca}", file=sys.stderr)
        sys.exit(1)

    password = args.password
    if password is None:
        password = getpass.getpass(f"Password for {args.p12.name} (CERT_PASS in .env): ")

    uid = args.uid or f"test-{uuid.uuid4()}"

    print(f"Loading client identity from {args.p12}...")
    cert_pem, key_pem = load_client_identity(args.p12, password.encode("utf-8"))

    print(f"Building TLS context (trusting {args.ca})...")
    context = build_ssl_context(args.ca, cert_pem, key_pem)

    cot_xml = build_test_cot(args.lat, args.lon, uid, args.callsign, args.stale_minutes)

    try:
        send_cot(args.host, args.port, context, cot_xml, args.read_timeout)
    except ssl.SSLCertVerificationError as e:
        print(f"ERROR: server cert did not verify against {args.ca}: {e}", file=sys.stderr)
        sys.exit(1)
    except ssl.SSLError as e:
        print(f"ERROR: TLS handshake failed - likely a bad/unaccepted client cert: {e}", file=sys.stderr)
        sys.exit(1)
    except (ConnectionRefusedError, socket.timeout, socket.gaierror) as e:
        print(f"ERROR: could not reach {args.host}:{args.port}: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
