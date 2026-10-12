#!/usr/bin/env python3
"""TCP proxy that makes a Kubernetes API server look slow and unreliable.

Test helper for k8s-perf-collector.sh's timeout and error handling. Each new
client connection is, at random (seeded, so runs are repeatable):
  * held for --delay seconds before being forwarded -> client-side timeouts
  * reset immediately (TCP RST)                     -> connection errors
  * forwarded untouched
The first --clean-first connections are always forwarded so the collector's
connectivity check passes.

  ./flaky-apiserver-proxy.py --upstream 127.0.0.1:6443 --listen 127.0.0.1:16443

Point a copy of your kubeconfig at https://127.0.0.1:16443 - the API server
certificate is normally valid for 127.0.0.1 (kind, kubeadm), so TLS still
verifies - and run the collector with --kubeconfig and a short --timeout.
"""
import argparse
import asyncio
import random
import socket
import struct
import sys


def host_port(value):
    host, _, port = value.rpartition(":")
    return host or "127.0.0.1", int(port)


async def pipe(reader, writer):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (ConnectionError, asyncio.CancelledError):
        pass
    finally:
        writer.close()


async def handle(client_reader, client_writer, args, state):
    state["connections"] += 1
    n = state["connections"]
    roll = state["rng"].random()
    action = "forward"
    if n > args.clean_first:
        if roll < args.reset_ratio:
            action = "reset"
        elif roll < args.reset_ratio + args.delay_ratio:
            action = "delay"
    print(f"connection {n}: {action}", file=sys.stderr, flush=True)

    if action == "reset":
        sock = client_writer.get_extra_info("socket")
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        client_writer.close()
        return
    if action == "delay":
        await asyncio.sleep(args.delay)

    try:
        up_reader, up_writer = await asyncio.open_connection(*args.upstream)
    except OSError as exc:
        print(f"connection {n}: upstream error {exc}", file=sys.stderr, flush=True)
        client_writer.close()
        return
    await asyncio.gather(pipe(client_reader, up_writer), pipe(up_reader, client_writer))


async def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--upstream", type=host_port, required=True, help="API server host:port")
    parser.add_argument("--listen", type=host_port, default=("127.0.0.1", 16443), help="listen host:port")
    parser.add_argument("--delay-ratio", type=float, default=0.25, help="share of connections to delay")
    parser.add_argument("--delay", type=float, default=8.0, help="seconds to hold a delayed connection")
    parser.add_argument("--reset-ratio", type=float, default=0.10, help="share of connections to reset")
    parser.add_argument("--clean-first", type=int, default=3, help="connections always forwarded first")
    parser.add_argument("--seed", type=int, default=42, help="random seed")
    args = parser.parse_args()

    state = {"connections": 0, "rng": random.Random(args.seed)}
    server = await asyncio.start_server(lambda r, w: handle(r, w, args, state), *args.listen)
    print(f"listening on {args.listen[0]}:{args.listen[1]} -> {args.upstream[0]}:{args.upstream[1]}",
          file=sys.stderr, flush=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
