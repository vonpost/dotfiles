#!/usr/bin/env python3
"""Exercise an exported MAMORU ruleset in disposable, rootless namespaces.

Usage: python3 tests/infra/test_packets.py /tmp/mamoru.nft
Requires Linux user/network namespaces, iproute2, nftables and util-linux.
No production interfaces, firewall rules or network services are touched.
"""

import os
from pathlib import Path
import subprocess
import sys


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


SERVER = """
import selectors, socket, sys
selector = selectors.DefaultSelector()
for endpoint in sys.argv[1:]:
    protocol, port = endpoint.split(':')
    for family, address in [(socket.AF_INET, '0.0.0.0'), (socket.AF_INET6, '::')]:
        sock = socket.socket(family, socket.SOCK_STREAM if protocol == 'tcp' else socket.SOCK_DGRAM)
        if family == socket.AF_INET6: sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        sock.bind((address, int(port)))
        if protocol == 'tcp': sock.listen()
        selector.register(sock, selectors.EVENT_READ, protocol)
print('ready', flush=True)
while True:
    for key, _ in selector.select():
        if key.data == 'tcp':
            conn, _ = key.fileobj.accept()
            with conn: conn.sendall(b'ok')
        else:
            _, address = key.fileobj.recvfrom(1024)
            key.fileobj.sendto(b'ok', address)
"""

CLIENT = """
import socket, sys
protocol, address, port = sys.argv[1:]
family = socket.AF_INET6 if ':' in address else socket.AF_INET
with socket.socket(family, socket.SOCK_STREAM if protocol == 'tcp' else socket.SOCK_DGRAM) as sock:
    sock.settimeout(0.7)
    try:
        sock.connect((address, int(port)))
        if protocol == 'udp': sock.send(b'probe')
        data = sock.recv(2)
    except (TimeoutError, ConnectionError, OSError):
        sys.exit(1)
    sys.exit(0 if data == b'ok' else 2)
"""


def exercise(rules):
    children = []
    namespaces = {}

    def ipv6(address):
        network, host = address.split('.')[-2:]
        return f'fd00:{network}::{host}'

    def inside(name, *args, **kwargs):
        return run('nsenter', f'--net=/proc/{namespaces[name]}/ns/net', *args, **kwargs)

    try:
        run('ip', 'link', 'set', 'lo', 'up')
        for segment, address in [('mgmt', '10.10.10.10'), ('srv', '10.10.20.10'),
                                 ('dmz', '10.10.30.10'), ('wan', '192.0.2.10')]:
            run('ip', 'link', 'add', segment, 'type', 'bridge')
            run('ip', 'addr', 'add', f'{address}/24', 'dev', segment)
            run('ip', '-6', 'addr', 'add', f'{ipv6(address)}/64', 'dev', segment, 'nodad')
            run('ip', 'link', 'set', segment, 'up')
        Path('/proc/sys/net/ipv4/ip_forward').write_text('1\n')
        Path('/proc/sys/net/ipv6/conf/all/forwarding').write_text('1\n')
        # Avoid bridge-netfilter making direct same-segment packets traverse
        # the router rules on hosts where that optional module is loaded.
        bridge_filter = Path('/proc/sys/net/bridge/bridge-nf-call-iptables')
        if bridge_filter.exists():
            bridge_filter.write_text('0\n')
        bridge_filter6 = Path('/proc/sys/net/bridge/bridge-nf-call-ip6tables')
        if bridge_filter6.exists():
            bridge_filter6.write_text('0\n')

        machines = [
            ('soto', 'dmz', '10.10.30.25', ['tcp:443', 'tcp:8096']),
            ('uchi', 'srv', '10.10.20.20', ['tcp:8989', 'tcp:9696']),
            ('kaizoku', 'srv', '10.10.20.15', []),
            ('nikki', 'mgmt', '10.10.10.35', []),
            ('dare', 'srv', '10.10.20.53', ['udp:53', 'tcp:53']),
            ('internet', 'wan', '192.0.2.2', ['tcp:443', 'tcp:9000']),
        ]
        for name, segment, address, endpoints in machines:
            # The child signals readiness only after unshare has completed.
            child = subprocess.Popen(['unshare', '--net', sys.executable, '-u', '-c',
                                      "import time; print('ready', flush=True); time.sleep(120)"],
                                     stdout=subprocess.PIPE, text=True)
            children.append(child)
            assert child.stdout.readline().strip() == 'ready'
            namespaces[name] = child.pid
            run('ip', 'link', 'add', f'v-{name}', 'type', 'veth', 'peer', 'name', f'p-{name}')
            run('ip', 'link', 'set', f'v-{name}', 'master', segment)
            run('ip', 'link', 'set', f'v-{name}', 'up')
            run('ip', 'link', 'set', f'p-{name}', 'netns', str(child.pid))
            inside(name, 'ip', 'link', 'set', 'lo', 'up')
            inside(name, 'ip', 'addr', 'add', f'{address}/24', 'dev', f'p-{name}')
            inside(name, 'ip', '-6', 'addr', 'add', f'{ipv6(address)}/64', 'dev', f'p-{name}', 'nodad')
            inside(name, 'ip', 'link', 'set', f'p-{name}', 'up')
            gateway = address.rsplit('.', 1)[0] + '.10'
            inside(name, 'ip', 'route', 'add', 'default', 'via', gateway)
            inside(name, 'ip', '-6', 'route', 'add', 'default', 'via', ipv6(gateway))
            if endpoints:
                server = subprocess.Popen(['nsenter', f'--net=/proc/{child.pid}/ns/net',
                                           sys.executable, '-u', '-c', SERVER, *endpoints],
                                          stdout=subprocess.PIPE, text=True)
                children.append(server)
                assert server.stdout.readline().strip() == 'ready'

        # A real listener makes the denied router-input case distinguish a
        # firewall drop from an ordinary closed port.
        router_server = subprocess.Popen([sys.executable, '-u', '-c', SERVER, 'tcp:22'],
                                         stdout=subprocess.PIPE, text=True)
        children.append(router_server)
        assert router_server.stdout.readline().strip() == 'ready'
        run('nft', '--check', '--file', rules)
        run('nft', '--file', rules)
        cases = [
            ('routed Sonarr', 'soto', 'tcp', '10.10.20.20', 8989, True),
            ('same-segment Sonarr', 'kaizoku', 'tcp', '10.10.20.20', 8989, True),
            ('routed Jellyfin', 'uchi', 'tcp', '10.10.30.25', 8096, True),
            ('unlisted routed Jellyfin', 'kaizoku', 'tcp', '10.10.30.25', 8096, False),
            ('management blanket access', 'nikki', 'tcp', '10.10.20.20', 9696, True),
            ('DNS UDP', 'soto', 'udp', '10.10.20.53', 53, True),
            ('DNS TCP', 'soto', 'tcp', '10.10.20.53', 53, True),
            ('WAN HTTPS DNAT', 'internet', 'tcp', '192.0.2.10', 443, True),
            ('WAN router SSH denied', 'internet', 'tcp', '192.0.2.10', 22, False),
            ('DMZ HTTPS egress', 'soto', 'tcp', '192.0.2.2', 443, True),
            ('DMZ arbitrary egress denied', 'soto', 'tcp', '192.0.2.2', 9000, False),
            ('IPv6 server egress', 'uchi', 'tcp', 'fd00:2::2', 9000, True),
            ('IPv6 DMZ HTTPS egress', 'soto', 'tcp', 'fd00:2::2', 443, True),
            ('IPv6 DMZ arbitrary egress denied', 'soto', 'tcp', 'fd00:2::2', 9000, False),
            ('IPv6 inter-segment denied', 'nikki', 'tcp', 'fd00:20::20', 8989, False),
        ]
        for label, source, protocol, destination, port, expected in cases:
            result = subprocess.run(['nsenter', f'--net=/proc/{namespaces[source]}/ns/net',
                                     sys.executable, '-c', CLIENT, protocol, destination, str(port)])
            assert result.returncode in (0, 1), (label, result.returncode)
            assert (result.returncode == 0) == expected, f'{label}: expected reachable={expected}'
            print(f'PASS: {label}', flush=True)
        print(f'{len(cases)} packet checks passed. Guest firewalls require separate checks.')
    finally:
        for child in reversed(children):
            child.terminate()
        for child in children:
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()


if __name__ == '__main__':
    if len(sys.argv) == 2:
        rules = str(Path(sys.argv[1]).resolve(strict=True))
        original = os.readlink('/proc/self/ns/net')
        os.execvp('unshare', ['unshare', '--user', '--map-root-user', '--net',
                             sys.executable, __file__, '--isolated', original, rules])
    elif len(sys.argv) == 4 and sys.argv[1] == '--isolated':
        # Even the internal entry point refuses the original network namespace.
        assert os.readlink('/proc/self/ns/net') != sys.argv[2]
        assert Path('/proc/self/uid_map').read_text().split()[-1] == '1'
        exercise(sys.argv[3])
    else:
        sys.exit(__doc__)
