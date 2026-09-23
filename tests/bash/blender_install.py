#!/usr/bin/env python3
"""Run the installer against isolated fake applications, never /Applications."""
import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class InstallTests(unittest.TestCase):
    def run_install(self, fail_copy=False, invalid_image=False, fail_swap=False,
                    action='reinstall', latest='5.2.2', current='5.2.2',
                    offline=False, fail_extension=False, fail_setup=False, no_extensions=False, finder_path=False):
        with tempfile.TemporaryDirectory(prefix='blender install ') as tmp:
            root = pathlib.Path(tmp)
            app = root / 'Applications/Blender.app'
            cfg = root / 'config/dcc/blender'
            mount = root / 'mounted image'
            events = root / 'events'
            events.write_text('')
            fake_blender = '#!/bin/bash\nif [[ " $* " == *" --python "* ]]; then\n    echo "setup $OPS_BLENDER_ADDONS" >> "$TEST_EVENTS"\n    exit "$FAIL_SETUP"\nfi\necho "extension $*" >> "$TEST_EVENTS"\nexit "$FAIL_EXTENSION"\n'
            binary = mount / 'Blender.app/Contents/MacOS/Blender'
            binary.parent.mkdir(parents=True)
            if not invalid_image:
                binary.write_text(fake_blender)
                binary.chmod(0o755)
            (mount / 'Blender.app/Contents/Resources').mkdir()
            (app / 'Contents/Resources').mkdir(parents=True)
            (app / 'original').write_text('working installation')
            installed_binary = app / 'Contents/MacOS/Blender'
            installed_binary.parent.mkdir(parents=True)
            installed_binary.write_text(fake_blender)
            installed_binary.chmod(0o755)
            (cfg / 'portable').mkdir(parents=True)
            (cfg / 'extensions.txt').write_text('blender_org bool_tool\nforgejo projects.blender.org/lab/blender_mcp mcp\n')
            for module in ['blender_org/bool_tool', 'user_default/mcp']:
                manifest = cfg / 'portable/extensions' / module / 'blender_manifest.toml'
                manifest.parent.mkdir(parents=True)
                manifest.write_text('id = "' + module.split('/')[-1] + '"\n')
            if no_extensions:
                (cfg / 'extensions.txt').write_text('')
            if fail_extension:
                (cfg / 'portable/extensions/blender_org/bool_tool/blender_manifest.toml').unlink()
            (app / 'Contents/Resources/portable').symlink_to(cfg / 'portable')
            script = (ROOT / 'platforms/macos/installers/blender.sh').read_text()
            script = script.replace('REPO="$(cd "$(dirname "$0")/../../.." && pwd)"', f'REPO="{root}"')
            script = script.replace('/Applications', str(root / 'Applications'))
            (root / 'blender.sh').write_text(script)
            helpers = '''dl() { echo download >> "$TEST_EVENTS"; touch "$2"; }
dmg_attach() { printf '%s\\n' "$TEST_MOUNT"; }
dmg_detach() { :; }
curl() {
    if [ "$OFFLINE" = 1 ]; then echo 'curl: simulated timeout' >&2; return 28; fi
    printf 'Blender5.2/\\nblender-%s-macos-arm64.dmg\\nblender-%s-macos-x64.dmg\\n' "$LATEST" "$LATEST"
}
defaults() { echo "$CURRENT"; }
claude() { :; }
uvx() { :; }
mv() { if [ "$FAIL_SWAP" = 1 ] && [[ "$1" == */.blender-install.*/Blender.app ]]; then return 1; fi; command mv "$@"; }
ditto() { if [ "$FAIL_COPY" = 1 ]; then return 1; fi; cp -R "$1" "$2"; }
'''
            extra_env = {}
            if finder_path:
                helpers = helpers.replace('claude() { :; }\nuvx() { :; }\n', '')
                local_bin = root / 'home/.local/bin'
                local_bin.mkdir(parents=True)
                for tool in ['claude', 'uvx']:
                    stub = local_bin / tool
                    stub.write_text('#!/bin/sh\nprintf \'mcp-call %s\\n\' "$*" >> "$TEST_EVENTS"\n')
                    stub.chmod(0o755)
                extra_env = {'HOME': str(root / 'home'), 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin'}
            (root / '_lib.sh').write_text(helpers)
            result = subprocess.run(['/bin/bash', str(root / 'blender.sh'), action],
                                    env={**os.environ, 'TEST_MOUNT': str(mount), 'FAIL_COPY': str(int(fail_copy)), 'FAIL_SWAP': str(int(fail_swap)), 'LATEST': latest, 'CURRENT': current, 'OFFLINE': str(int(offline)), 'TEST_EVENTS': str(events), 'FAIL_EXTENSION': str(int(fail_extension)), 'FAIL_SETUP': str(int(fail_setup)), **extra_env},
                                    capture_output=True, text=True, timeout=10)
            event_log = events.read_text()
            if finder_path:
                self.assertIn(f'mcp add -s user blender -- {local_bin}/uvx --refresh-package', event_log)
                self.assertNotIn('skip MCP registration', result.stdout)
            replace = action == 'reinstall' or action != 'configure' and (not offline and tuple(map(int, latest.split('.'))) > tuple(map(int, current.split('.'))))
            if fail_copy or invalid_image or fail_swap or (offline and (action == 'reinstall' or not current)):
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue((app / 'original').exists())
                self.assertNotIn('setup ', event_log)
                if offline:
                    self.assertNotIn('download', event_log)
            else:
                self.assertEqual(result.returncode, int(fail_extension or fail_setup), result.stdout + result.stderr)
                self.assertIn('setup ' if no_extensions else 'setup bl_ext.blender_org.bool_tool bl_ext.user_default.mcp', event_log)
                self.assertEqual('download' in event_log, replace)
                self.assertTrue((app / 'Contents/MacOS/Blender').exists())
                self.assertTrue((app / 'Contents/Resources/portable').is_symlink())
                self.assertEqual((app / 'original').exists(), not replace)
                if offline:
                    self.assertIn('could not check for a newer Blender', result.stdout + result.stderr)
                # A clean setup stamps the config; editing an input reads as outdated again.
                status = lambda: subprocess.run(['/bin/bash', str(root / 'blender.sh'), 'status'],
                                                capture_output=True, text=True).stdout
                self.assertEqual('outdated' in status(), bool(fail_extension or fail_setup))
                (cfg / 'extensions.txt').write_text('blender_org another\n')
                self.assertIn('outdated', status())
            self.assertEqual(list((root / 'Applications').glob('.blender-install.*')), [])

    def test_finder_path_finds_native_claude_and_registers_absolute_uvx(self):
        self.run_install(action='update', finder_path=True)

    def test_reinstall_requires_a_resolved_download(self):
        self.run_install(action='reinstall', offline=True)

    def test_install_without_known_version_cannot_assume_latest_when_offline(self):
        self.run_install(action='install', current='', offline=True)

    def test_empty_extension_list_still_reapplies_setup(self):
        self.run_install(action='update', no_extensions=True)

    def test_configure_reapplies_setup_without_version_check(self):
        self.run_install(action='configure', latest='5.2.10')

    def test_update_same_version_reapplies_setup_without_download(self):
        self.run_install(action='update')

    def test_update_offline_reapplies_setup_without_download(self):
        self.run_install(action='update', offline=True)

    def test_update_newer_version_downloads_and_reapplies_setup(self):
        self.run_install(action='update', latest='5.2.10')

    def test_update_does_not_downgrade(self):
        self.run_install(action='update', current='5.3.0')

    def test_extension_failure_does_not_skip_custom_setup(self):
        self.run_install(action='update', fail_extension=True)

    def test_setup_failure_is_reported(self):
        self.run_install(action='update', fail_setup=True)

    def test_success(self):
        self.run_install()

    def test_failed_copy_preserves_existing_installation(self):
        self.run_install(fail_copy=True)

    def test_failed_swap_restores_existing_installation(self):
        self.run_install(fail_swap=True)

    def test_invalid_image_preserves_existing_installation(self):
        self.run_install(invalid_image=True)


if __name__ == '__main__':
    unittest.main()
