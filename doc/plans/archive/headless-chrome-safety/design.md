# Headless Chrome wrapper safety

## Ownership

Every `run -- <command>` allocates a fresh private profile and records the owner's PID/start identity. Inherited CHROME_PROFILE values are ignored, never reused or deleted. Sweep handles only marked profiles from ended owners; unmarked directories and live runs are preserved. Standalone `path` allocation is removed because a returned directory cannot propagate process ownership into the caller.

## Process lifetime

The probe runs in a dedicated process group under an interruptible wait. Wrapper-only INT/TERM can therefore stop it without waiting for the probe to exit first. A per-run marker is inherited by descendants; exact environment lookup identifies detached browser/helper groups without matching neighboring profile names or marker-looking command arguments. The Python 3 standard-library reader uses Darwin process arguments/environment boundaries or Linux `/proc`, restricted to the same effective user, and emits only PID/PGID pairs. Full environments are never logged. Missing dependencies, unsupported systems or required inspection failures produce an error and retain recovery state.

SIGKILL cannot be trapped, so sweep uses the ownership records and inherited marker to recover ended runs. Processes that detach and strip the marker, change credentials or become inaccessible to the operating-system reader are outside this recovery contract. There is no global Chrome kill or guaranteed cleanup claim.

## Client contract

Playwright probes retain explicit close in `finally`: `context.close()` for the wrapper-owned persistent context, or `browser.close()` for an existing browser handle. The wrapper is crash recovery, not normal shutdown. Callers supplying custom environments retain the inherited marker. An open browser or referenced child stream can keep Node alive and prevent the wrapper's EXIT cleanup from starting.

## Verification boundary

Persistent CLI tests cover profile/caller data ownership, failed commands, wrapper-only INT/TERM, SIGKILL plus sweep, concurrent-run isolation, detached helpers, exact environment versus argv, missing dependencies, recovery-state retention and real Playwright lifecycle. A real-browser isolated API/CORS probe exercises the existing Swagger/settings flows through the wrapper, then independently checks profile removal and zero owned survivors. No physical-device operation or publication is part of this follow-up.
