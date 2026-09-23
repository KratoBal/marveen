import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
# A TESZT EGY SZINTTEL LEJJEBB AL, MINT A KAPU, es ez SZANDEKOS: a
# hook-registration-completeness orzo a scripts/hooks/ MINDEN .py fajljat
# szallitott hooknak veszi, tehat egy teszt-fajl ott bekotetlen hookkent
# jelenne meg (merve 2026-09-23: pontosan ez tortent).
_SCRIPT_PATH = os.path.join(os.path.dirname(_HERE), "readonly-command-gate.py")


def _load_gate_module():
    """Loads the gate by its actual (hyphenated) file path -- the deployed
    name matches the scripts/hooks/ sibling convention (outgoing-copy-gate.py,
    provenance-gate.py), which is not a valid `import` identifier, so this
    loads it via importlib instead of requiring a parallel underscore-named
    copy just for testing."""
    spec = importlib.util.spec_from_file_location("readonly_command_gate", _SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


gate = _load_gate_module()

REAL_PROFILE = "/home/marveen/marveen/templates/profiles/researcher-reader.json"

# Where the script is EXPECTED to live once deployed (this test file's own
# purpose: acrobot copies readonly-command-gate.py from this directory to
# here). Until it is actually there, the CLI-contract-at-the-real-path test
# below skips rather than failing -- "not deployed yet" is not "broken".
DEPLOYED_SCRIPT = "/home/marveen/marveen/scripts/hooks/readonly-command-gate.py"


class CliContractAtTheRealDeployedPath(unittest.TestCase):
    """Invokes the ACTUAL deployed file, as a real subprocess, stdin/stdout,
    once it exists at scripts/hooks/. This is the level acrobot's brief
    describes -- the hook contract, not the Python function -- and it is
    the only way to catch a bug like the first draft's: $HOME-dependent
    path resolution that works when murena runs it and silently breaks
    under barracuda's own $HOME. A same-directory copy would hide exactly
    that bug; only testing from the REAL relative depth catches it.
    """

    def setUp(self):
        if not os.path.exists(DEPLOYED_SCRIPT):
            self.skipTest(
                "not deployed yet at " + DEPLOYED_SCRIPT
                + " -- this is expected before acrobot places the file"
            )

    def run_gate(self, command):
        payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": command}})
        result = subprocess.run(
            [sys.executable, DEPLOYED_SCRIPT],
            input=payload, capture_output=True, text=True, timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def test_real_case_allowed_over_subprocess(self):
        out = self.run_gate(
            'S=/tmp/claude-1003/scratchpad\n'
            '/bin/grep -vP mintat "$S/a.tsv"'
        )
        self.assertTrue(out, "expected an allow decision on stdout, got nothing")
        parsed = json.loads(out)
        self.assertEqual(parsed["hookSpecificOutput"]["permissionDecision"], "allow")

    def test_forbidden_token_path_silent_over_subprocess(self):
        out = self.run_gate("cat /whatever/store/.dashboard-token")
        self.assertEqual(out, "", "a forbidden command must print NOTHING")


class CliContractFromASyntheticDeploymentDepth(unittest.TestCase):
    """Same subprocess-level contract, but runnable RIGHT NOW, before the
    file is actually deployed: builds a throwaway copy at the same relative
    depth (<tmp>/scripts/hooks/<file> next to <tmp>/templates/profiles/...)
    from the two REAL, readable files, so _install_dir()'s own path
    resolution is exercised for real, not skipped over.
    """

    @classmethod
    def setUpClass(cls):
        if not os.path.exists(REAL_PROFILE):
            raise unittest.SkipTest("live profile not readable in this environment")
        cls.tmp = tempfile.mkdtemp(prefix="readonly-gate-synth-")
        hooks_dir = os.path.join(cls.tmp, "scripts", "hooks")
        profiles_dir = os.path.join(cls.tmp, "templates", "profiles")
        os.makedirs(hooks_dir)
        os.makedirs(profiles_dir)
        cls.script = os.path.join(hooks_dir, "readonly-command-gate.py")
        shutil.copy(_SCRIPT_PATH, cls.script)
        shutil.copy(REAL_PROFILE, os.path.join(profiles_dir, "researcher-reader.json"))

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def run_gate(self, command):
        payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": command}})
        result = subprocess.run(
            [sys.executable, self.script],
            input=payload, capture_output=True, text=True, timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def test_real_case_allowed_over_subprocess(self):
        out = self.run_gate(
            'S=/tmp/claude-1003/scratchpad\n'
            '/bin/grep -vP mintat "$S/a.tsv"'
        )
        self.assertTrue(out, "expected an allow decision on stdout, got nothing")
        parsed = json.loads(out)
        self.assertEqual(parsed["hookSpecificOutput"]["permissionDecision"], "allow")

    def test_bare_variable_no_assignment_silent_over_subprocess(self):
        # The ORIGINAL "must pass" case from the first brief, without the
        # assignment. Tightened per acrobot's 2026-09-23 follow-up: an
        # unresolved variable must fall back to asking, not pass on the
        # strength of the literal remainder.
        out = self.run_gate('/bin/grep -vP mintat "$S/a.tsv"')
        self.assertEqual(out, "")

    def test_forbidden_token_path_silent_over_subprocess(self):
        out = self.run_gate("cat /whatever/store/.dashboard-token")
        self.assertEqual(out, "", "a forbidden command must print NOTHING")

    def test_chain_to_rm_silent_over_subprocess(self):
        out = self.run_gate("cat a.txt; rm -rf b")
        self.assertEqual(out, "")

    def test_redirect_silent_over_subprocess(self):
        out = self.run_gate("sort fajl > masik")
        self.assertEqual(out, "")

    def test_substitution_silent_over_subprocess(self):
        out = self.run_gate("echo $(cat /x/store/titok)")
        self.assertEqual(out, "")

    def test_sed_inplace_silent_over_subprocess(self):
        out = self.run_gate("sed -i s/a/b/ fajl")
        self.assertEqual(out, "")

    def test_channels_config_silent_over_subprocess(self):
        out = self.run_gate("grep -r titok /whatever/.channels-config/")
        self.assertEqual(out, "")


class DecideAgainstRealProfile(unittest.TestCase):
    """Runs against the ACTUAL live profile file (read-only access), not a
    copy -- so a change to the profile's allow/deny lists is picked up by
    these tests automatically, and a stale hand-typed fixture can never
    drift from what barracuda's profile really says."""

    def setUp(self):
        if not os.path.exists(REAL_PROFILE):
            self.skipTest("live profile not readable in this environment")

    def allow(self, cmd):
        return gate.decide("Bash", {"command": cmd}, REAL_PROFILE)

    # --- the seven required cases, verbatim from the brief -----------------

    def test_token_read_blocked(self):
        self.assertIsNone(self.allow('cat /whatever/store/.dashboard-token'))

    def test_channels_config_grep_blocked(self):
        self.assertIsNone(
            self.allow('grep -r titok /whatever/.channels-config/')
        )

    def test_redirect_blocked(self):
        self.assertIsNone(self.allow('sort fajl > masik'))

    def test_chain_to_unlisted_blocked(self):
        self.assertIsNone(self.allow('cat a.txt; rm -rf b'))

    def test_substitution_blocked(self):
        self.assertIsNone(
            self.allow('echo $(cat /whatever/store/titok)')
        )

    def test_sed_inplace_blocked(self):
        self.assertIsNone(self.allow('sed -i s/a/b/ fajl'))

    def test_real_variable_case_allowed_with_assignment(self):
        # barracuda's ACTUAL shape (acrobot's correction, 2026-09-23): the
        # assignment is in the same block, on its own line, before use.
        result = self.allow(
            'S=/tmp/claude-1003/scratchpad\n'
            '/bin/grep -vP mintat "$S/a.tsv"'
        )
        self.assertIsNotNone(result, "the motivating real case must pass")

    def test_bare_variable_without_assignment_now_blocked(self):
        # TIGHTENED, 2026-09-23: without a same-block assignment for $S,
        # this must NOT auto-allow any more, even though no deny fragment
        # is visible in the literal text -- acrobot's explicit rule is
        # "unresolvable => ask", not "unresolvable => trust the remainder".
        self.assertIsNone(self.allow('/bin/grep -vP mintat "$S/a.tsv"'))

    # --- extra coverage: the shape of each rejection, not just the case ----

    def test_backtick_substitution_blocked(self):
        self.assertIsNone(self.allow("echo `cat /etc/passwd`"))

    def test_double_redirect_blocked(self):
        self.assertIsNone(self.allow("cat a.txt >> b.txt"))

    def test_sed_in_place_long_flag_blocked(self):
        self.assertIsNone(self.allow("sed --in-place s/a/b/ fajl"))

    def test_sed_combined_short_flags_with_i_blocked(self):
        # "-ni" bundles quiet + in-place; the letter check must catch this,
        # not just the standalone "-i" token.
        self.assertIsNone(self.allow("sed -ni '1p' fajl"))

    def test_sed_dash_n_alone_allowed(self):
        self.assertIsNotNone(self.allow("sed -n '1,5p' fajl.txt"))

    def test_find_with_delete_blocked(self):
        self.assertIsNone(
            self.allow('find /home/marveen/marveen -name "*.tmp" -delete')
        )

    def test_find_with_exec_blocked(self):
        self.assertIsNone(
            self.allow('find /home/marveen/marveen -name x -exec rm {} \\;')
        )

    def test_find_plain_allowed(self):
        result = self.allow('find /home/marveen/marveen -name "*.md"')
        self.assertIsNotNone(result)

    def test_ampersand_background_blocked(self):
        self.assertIsNone(self.allow("cat a.txt &"))

    def test_unterminated_quote_blocked(self):
        self.assertIsNone(self.allow('grep "unterminated'))

    def test_env_reference_resolved_without_fragment_allowed(self):
        result = self.allow(
            'SCRATCH=/tmp/x\ncat "$SCRATCH/file.txt"'
        )
        self.assertIsNotNone(result)

    def test_env_reference_unassigned_blocked_even_without_fragment(self):
        # TIGHTENED, 2026-09-23: no assignment anywhere in the block, so
        # $SCRATCH cannot be resolved -- must block regardless of whether
        # the literal remainder looks clean.
        self.assertIsNone(self.allow('cat "$SCRATCH/file.txt"'))

    def test_env_reference_with_literal_store_fragment_blocked(self):
        # even without resolving $S, the literal "store/" text is right
        # there in the command -- must still be caught (and would ALSO be
        # caught by the unresolved-variable rule alone).
        self.assertIsNone(self.allow('cat "$S/store/secret"'))

    def test_env_reference_resolved_to_denied_fragment_blocked(self):
        # this time $S IS resolvable (same-block assignment) -- and the
        # RESOLVED value itself lands under store/. Must still block: the
        # deny-fragment check runs on the substituted text, not just the
        # raw one.
        self.assertIsNone(self.allow(
            'S=/home/marveen/marveen/store\ncat "$S/secret"'
        ))

    def test_chained_two_safe_commands_with_semicolon_allowed(self):
        result = self.allow("cat a.txt; wc -l a.txt")
        self.assertIsNotNone(result)

    def test_chained_two_safe_commands_with_and_allowed(self):
        result = self.allow("grep foo a.txt && wc -l a.txt")
        self.assertIsNotNone(result)

    def test_piped_safe_commands_allowed(self):
        result = self.allow("grep foo a.txt | sort | uniq -c")
        self.assertIsNotNone(result)

    def test_piped_to_unsafe_command_blocked(self):
        self.assertIsNone(self.allow("cat a.txt | sh"))

    def test_unknown_binary_blocked(self):
        self.assertIsNone(self.allow("python3 -c 'print(1)'"))

    def test_sudo_blocked(self):
        self.assertIsNone(self.allow("sudo cat /etc/shadow"))

    def test_empty_command_returns_none(self):
        self.assertIsNone(self.allow(""))

    def test_non_bash_tool_returns_none(self):
        self.assertIsNone(
            gate.decide("Read", {"file_path": "/x"}, REAL_PROFILE)
        )

    def test_missing_profile_returns_none(self):
        self.assertIsNone(
            gate.decide("Bash", {"command": "cat a.txt"}, "/no/such/file.json")
        )

    def test_multiline_command_chain_to_unsafe_blocked(self):
        # newline is now a segment separator (shell-equivalent to ";"), not
        # an automatic reject -- this is blocked because "rm" is unsafe,
        # not because of the newline itself.
        self.assertIsNone(self.allow("cat a.txt\nrm b.txt"))

    def test_multiline_command_both_safe_allowed(self):
        result = self.allow("cat a.txt\nwc -l a.txt")
        self.assertIsNotNone(result)

    def test_full_path_binary_allowed(self):
        result = self.allow("/usr/bin/grep foo /home/marveen/marveen/README.md")
        self.assertIsNotNone(result)

    def test_env_assignment_prefix_still_checks_program(self):
        # LC_ALL=C grep ... -- the leading assignment must be skipped, not
        # mistaken for the program name.
        result = self.allow("LC_ALL=C grep foo a.txt")
        self.assertIsNotNone(result)


class PureUnitTests(unittest.TestCase):
    """Same checks, but against a MINIMAL synthetic profile, so the pure
    parsing/decision logic is verifiable even without the live file."""

    PROFILE = {
        "filesystem": {
            "allow": [
                "Bash(grep:*)",
                "Bash(/bin/grep:*)",
                "Bash(cat:*)",
                "Bash(sort:*)",
                "Bash(sed -n:*)",
                "Bash(sed:*)",
                "Bash(find ${AGENT_DIR}:*)",
                "Bash(bash ${HOME}/marveen/scripts/unas.sh:*)",
            ],
            "deny": [
                "Read(${HOME}/marveen/.channels-config/**)",
                "Read(${HOME}/marveen/store/**)",
                "Read(**/.env)",
            ],
        }
    }

    def test_safe_bins_excludes_named_scripts(self):
        bins = gate.read_only_binaries_from_profile(self.PROFILE)
        self.assertIn("grep", bins)
        self.assertIn("cat", bins)
        self.assertNotIn("bash", bins)
        self.assertNotIn("unas.sh", bins)

    def test_deny_fragments_are_segment_names_not_full_paths(self):
        frags = gate.deny_fragments_from_profile(self.PROFILE)
        self.assertIn("store", frags, frags)
        self.assertIn(".channels-config", frags, frags)
        self.assertIn(".env", frags, frags)

    def test_deny_fragment_matches_any_prefix(self):
        # the whole point: no dependence on the resolved ${HOME} absolute
        # prefix, so a different base (a variable, a symlink, a relative
        # path) is still caught.
        self.assertTrue(gate._matches_deny_fragment("/whatever/store/x", "store"))
        self.assertTrue(gate._matches_deny_fragment("store/x", "store"))
        self.assertFalse(gate._matches_deny_fragment("/x/restore/y", "store"))

    def test_positive_control_known_bad_is_rejected(self):
        # if this ever passes, the harness itself is broken -- rm is never
        # on any read-only list, in any profile.
        safe = gate.read_only_binaries_from_profile(self.PROFILE)
        deny = gate.deny_fragments_from_profile(self.PROFILE)
        self.assertFalse(gate.is_readonly_command("rm -rf /", safe, deny))

    # --- variable-binding resolution (acrobot's 2026-09-23 follow-up) ------

    def test_pure_assignment_tokens_recognised(self):
        pairs = gate._pure_assignment_tokens(["S=/tmp/x"])
        self.assertEqual(pairs, [("S", "/tmp/x")])

    def test_pure_assignment_tokens_multiple_in_one_segment(self):
        pairs = gate._pure_assignment_tokens(["A=1", "B=2"])
        self.assertEqual(pairs, [("A", "1"), ("B", "2")])

    def test_pure_assignment_tokens_none_when_a_command_follows(self):
        # "S=/tmp/x cat file" -- a leading assignment scoped to a command,
        # not a standalone variable-definition statement. Must NOT be
        # treated as a pure assignment segment (that path is handled
        # separately, by stripping the ENV_ASSIGN prefix before the
        # program-name check).
        self.assertIsNone(gate._pure_assignment_tokens(["S=/tmp/x", "cat", "file"]))

    def test_resolve_or_flag_substitutes_known_binding(self):
        resolved, ok = gate._resolve_or_flag("$S/a.tsv", {"S": "/tmp/x"})
        self.assertTrue(ok)
        self.assertEqual(resolved, "/tmp/x/a.tsv")

    def test_resolve_or_flag_braced_form(self):
        resolved, ok = gate._resolve_or_flag("${S}/a.tsv", {"S": "/tmp/x"})
        self.assertTrue(ok)
        self.assertEqual(resolved, "/tmp/x/a.tsv")

    def test_resolve_or_flag_unknown_variable_flags_not_ok(self):
        resolved, ok = gate._resolve_or_flag("$S/a.tsv", {})
        self.assertFalse(ok)

    def test_resolve_or_flag_plain_text_untouched(self):
        resolved, ok = gate._resolve_or_flag("a.tsv", {"S": "/tmp/x"})
        self.assertTrue(ok)
        self.assertEqual(resolved, "a.tsv")

    def test_assignment_value_with_nested_variable_not_bound(self):
        # S=$OTHER/x -- not a SIMPLE assignment (references another
        # variable), so it must NOT become a resolvable binding; a later
        # $S reference should still fail resolution.
        safe = gate.read_only_binaries_from_profile(self.PROFILE)
        deny = gate.deny_fragments_from_profile(self.PROFILE)
        self.assertFalse(gate.is_readonly_command(
            'S=$OTHER/x\ncat "$S/file"', safe, deny,
        ))


if __name__ == "__main__":
    unittest.main()
