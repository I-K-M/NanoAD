# N03 native AD reference — acceptance checklist

No genuine Windows guest has been executed by CI or by the author. Syntax and pure identity tests are not native fidelity evidence.

1. Complete N01/N02 and record a disposable independent clone with the exact same Windows build/patches as the planned optimised candidate. Check provider-side network isolation before boot.
2. Verify that the guest guard rejects a non-Core, non-VirtualBox, mismatched name, joined guest, missing static address, external DNS and default route. Never run mutations against an unrelated system.
3. Run the plan twice; verify no marker, role, domain or state change. Provision with explicit authorisation; capture native prerequisite/promotion outcome, reboot and readiness.
4. Run Test-NanoADCore.ps1; retain JSON and actual failed predicates. A core pass is not N03 completion.
5. Create the separate reference fixture; run the explicit authentication/ACL exercise. Verify a signed/sealed explicit Kerberos bind and allow/deny on the disabled target property, restoration, NTLM observation against the configured policy and negative bind outcome. Inspect the native Security log locally for event IDs and principal/time correspondence; aggregate counts alone do not establish attribution. Record whether required audit policy was already configured. Do not weaken security or repeatedly submit incorrect passwords.
6. Shut down cleanly, start the same guest again and rerun core checks. Compare lab ID, changed boot timestamp, checks, AD identity and directory persistence. Verify no unexpected relevant system errors.
7. Record host memory, disk physical allocation and startup peak as the generous reference; use N04 for optimised candidates. Record missing/failed/inconclusive results and manually reviewed evidence. Do not qualify any configuration based on boot alone.

## Evidence record

Use the benchmark evidence schema in NAN-002: run ID, UTC times, git commit, provider/version, host and guest builds, image digest, allocation, check results, observed NTLM policy/outcome, audit correlation, restart comparison, isolation evidence, limitations and independent reviewer. Keep raw EVTX, secrets and media outside Git.

The repository CI parses scripts under both Windows PowerShell 5.1 and PowerShell 7 and runs the pure identity test. It deliberately does not install AD DS, create VMs or run the fixture.
