#!/usr/bin/env python3
"""Exercise the packaged stdio helper against an isolated running test registry."""
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import time


def main():
    process = subprocess.Popen([sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=os.environ)
    sequence = 0
    def send(value):
        process.stdin.write((json.dumps(value) + '\n').encode()); process.stdin.flush()
    def call(method, params):
        nonlocal sequence
        sequence += 1
        send({'jsonrpc': '2.0', 'id': sequence, 'method': method, 'params': params})
        end = time.monotonic() + 25
        while time.monotonic() < end:
            if not select.select([process.stdout], [], [], max(0, end-time.monotonic()))[0]:
                break
            line = process.stdout.readline()
            if not line:
                raise AssertionError('MCP helper closed stdout: ' + process.stderr.read().decode())
            message = json.loads(line)
            if message.get('id') == sequence:
                assert 'error' not in message, message
                return message['result']
        raise AssertionError('MCP response timed out: ' + method)
    def tool(name, arguments):
        return call('tools/call', {'name': name, 'arguments': arguments})
    try:
        initialized = call('initialize', {'protocolVersion': '2025-11-25', 'capabilities': {}, 'clientInfo': {'name': 'anywhere-test', 'version': '1'}})
        assert initialized['serverInfo']['name'] == 'anywhere', initialized
        send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
        tools = call('tools/list', {})['tools']
        assert {t['name'] for t in tools} == {'list', 'todo'}, tools
        discovery = tool('list', {'plugin': 'todo'})
        assert discovery['structuredContent']['plugins'][0]['name'] == 'todo', discovery
        created = tool('todo', {'operation': 'create', 'params': {'fields': {'title': 'MCP 实际调用'}}})
        assert not created.get('isError'), created
        item = created['structuredContent']['item']
        assert item['id'] and item['requestId'] is None, item
        updated = tool('todo', {'operation': 'update', 'params': {'id': item['id'], 'expectedVersion': item['version'], 'patch': {'note': 'via stdio'}}})
        assert not updated.get('isError'), updated
        stale = tool('todo', {'operation': 'update', 'params': {'id': item['id'], 'expectedVersion': item['version'], 'patch': {'note': 'stale'}}})
        assert stale.get('isError') and stale['structuredContent']['code'] == 'conflict', stale
        item = updated['structuredContent']['item']
        completed = tool('todo', {'operation': 'complete', 'params': {'id': item['id'], 'expectedVersion': item['version']}})
        assert completed['structuredContent']['item']['done'], completed
        listed = tool('todo', {'operation': 'list', 'params': {'status': 'completed'}})
        assert listed['structuredContent']['items'][0]['note'] == 'via stdio', listed
        revoke = os.environ.get('ANYWHERE_MCP_REVOKE_FILE')
        if revoke:
            Path(revoke).touch()
            end = time.monotonic() + 8
            changed = False
            while time.monotonic() < end:
                if not select.select([process.stdout], [], [], max(0, end-time.monotonic()))[0]:
                    break
                message = json.loads(process.stdout.readline())
                if message.get('method') == 'notifications/tools/list_changed':
                    changed = True
                    break
            assert changed, 'Tool revocation did not notify the connected MCP client'
            assert [t['name'] for t in call('tools/list', {})['tools']] == ['list']
            assert tool('todo', {'operation': 'list', 'params': {}}).get('isError')
        print('Packaged stdio MCP: initialize, discovery, create, update, conflict, complete, query and dynamic revocation passed.')
    finally:
        process.stdin.close()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.terminate(); process.wait(timeout=5)


if __name__ == '__main__':
    main()
