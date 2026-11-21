#!/usr/bin/env python3
"""Launch the LMCache MP server without the top-level `lmcache` CLI.

Why this exists: the consolidation branch (upstream-consolidation tip
gd6e402b2) has a bench command module mid-refactor — its verdict.py
imports a name that no longer exists in its sibling scoring.py — and
lmcache/cli/commands/__init__.py deliberately re-raises import errors
from command auto-discovery, so EVERY `lmcache <subcommand>` dies,
including `lmcache server`.

This shim is line-for-line the dispatch that lmcache.cli.commands.
server.ServerCommand.execute() performs: the same argparse groups, the
same parse_args_to_* calls, the same run_http_server entrypoint. It is
NOT a fork of any logic — when the CLI import is fixed upstream, the
launcher can go back to plain `lmcache server`.
"""
# Standard
import argparse
import sys


def main() -> None:
    # First Party
    from lmcache.v1.distributed.config import (
        add_storage_manager_args,
        parse_args_to_config,
    )
    from lmcache.v1.mp_observability.config import (
        add_observability_args,
        parse_args_to_observability_config,
    )
    from lmcache.v1.multiprocess.config import (
        add_coordinator_args,
        add_http_frontend_args,
        add_mp_server_args,
        add_p2p_args,
        parse_args_to_coordinator_config,
        parse_args_to_http_frontend_config,
        parse_args_to_mp_server_config,
    )
    from lmcache.v1.multiprocess.http_server import run_http_server

    parser = argparse.ArgumentParser(
        prog="lmcache-server-shim",
        description="LMCache MP server (direct dispatch, see file docstring)",
    )
    # The same six argument groups ServerCommand.register_cli() adds.
    add_mp_server_args(parser)
    add_p2p_args(parser)
    add_storage_manager_args(parser)
    add_http_frontend_args(parser)
    add_observability_args(parser)
    add_coordinator_args(parser)
    args = parser.parse_args()

    run_http_server(
        http_config=parse_args_to_http_frontend_config(args),
        mp_config=parse_args_to_mp_server_config(args),
        storage_manager_config=parse_args_to_config(args),
        obs_config=parse_args_to_observability_config(args),
        coordinator_config=parse_args_to_coordinator_config(args),
    )


if __name__ == "__main__":
    main()
