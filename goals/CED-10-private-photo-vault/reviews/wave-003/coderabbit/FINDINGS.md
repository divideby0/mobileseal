# CodeRabbit findings

Notice: Detected claude environment. Use `coderabbit review --agent` for structured agent-friendly output.
Connecting to CodeRabbit... 0s elapsed
Preparing review... 2s elapsed
────────────────────────────────────────
CodeRabbit Review

Diff : committed changes only
Compare : CED-10-private-photo-vault → main
Directory : CED-10-private-photo-vault
────────────────────────────────────────

(\(\
(• .•) Preventing the Matrix from glitching.

Summarizing changes... 3s elapsed
Writing review comments... 48s elapsed
Writing review comments... 1m 00s elapsed - still working

────────────────────────────────────────────────────────────────────────
major [Functional Correctness]
→ ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-10-private-photo-vault/goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/competitor/prompt.md:3goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/competitor/prompt.md:3-9]8;;

Use repository-relative paths for the session inputs and output.

These paths point to an obsolete worktree and goals/drafts/... tree.
Running the prompt from the current checkout will not find the referenced
context files and will write output.json outside the tracked
goals/CED-10-private-photo-vault/.../competitor/ directory.

Proposed fix

-CONTEXT FILES (read them first): /Users/openclaw/.../goals/drafts/20260718-164118-private-photo-vault/GOAL.md
+CONTEXT FILES (read them first): goals/CED-10-private-photo-vault/GOAL.md
...
-Write the JSON array to: /Users/openclaw/.../goals/drafts/20260718-164118-private-photo-vault/adhd/session-001-20260719-132924/competitor/output.json
+Write the JSON array to: goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/competitor/output.json

Writing review comments... 2m 32s elapsed - still working - 1 finding so far

────────────────────────────────────────────────────────────────────────
major [Data Integrity & Integration]
→ ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-10-private-photo-vault/goals/CED-10-private-photo-vault/reviews/wave-002/sonarqube/run.sh:8goals/CED-10-private-photo-vault/reviews/wave-002/sonarqube/run.sh:8-21]8;;

Use a unique project key for each review checkout.

The script claims per-branch isolation, but scan_project_key is a fixed
value and the scanner argument repeats that literal. Concurrent branches
or waves can overwrite the same Sonar project, causing the subsequent
issue query to report another checkout’s results. Derive one sanitized key
from an injected branch/commit identifier and use the variable
consistently.

Proposed fix

-scan_project_key='mobileseal-CED-10-private-photo-vault'
+scan_project_key="${SONAR_PROJECT_KEY:?set a unique per-review project key}"

-sonar-scanner '-Dsonar.projectKey=mobileseal-CED-10-private-photo-vault' '-Dsonar.projectName=mobileseal-CED-10-private-photo-vault' ...
+sonar-scanner "-Dsonar.projectKey=$scan_project_key" "-Dsonar.projectName=$scan_project_key" ...

────────────────────────────────────────────────────────────────────────
major [Security & Privacy]
→ ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-10-private-photo-vault/Sources/VaultCore/SecureBytes.swift:43Sources/VaultCore/SecureBytes.swift:43-77]8;;

Do not promise a full wipe for aliased arrays. inout [UInt8] only zeros
the current array storage; if another Array shares that storage, it
keeps the original bytes. Reword this as best-effort wiping, or switch to
a noncopyable/raw-buffer API if you need a true erase guarantee.

────────────────────────────────────────
Review complete
3 findings ✔

Major 3

107 files reviewed:

- .gitignore
- .swift-version
- CONTEXT.md
- Package.resolved
- Package.swift
- Sources/Argon2Bench/main.swift
- Sources/VaultCore/ChunkObject.swift
- Sources/VaultCore/ChunkReader.swift
- Sources/VaultCore/CryptoCore.swift
- Sources/VaultCore/Errors.swift
  ... and 97 more files
  ────────────────────────────────────────

Print all AI prompts: coderabbit review --show-prompts

REVIEW COMPLETE
