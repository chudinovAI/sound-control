# Sound Control

A native application mixer for macOS; the goal and criteria are in SPEC.md.

## Commands

- Build the `.app`: `./scripts/build-app.sh`.
- Launch the built application: `open 'build/Sound Control.app'`.

## Project memory

- At the start of work, read SPEC.md, ARCHITECTURE.md, and the current step in PLAN.md.
- PLAN.md is the local source of status. ARCHITECTURE.md reflects the actual responsibilities and important code contracts.
- Do not create GitHub infrastructure, publish the application, or change permissions without a corresponding instruction.

## Work and review

- Keep changes within the scope of the task, preserve user changes, and remove obsolete code after a contract changes.
- Verify actual behavior changes through a working entry point; report results and unverified scenarios separately.
- An independent reviewer checks substantial or risky changes. If there are findings: review0, fix1/review1, and, if necessary, fix2/review2; after the second unsuccessful review, stop the affected work and ask the user.
- Agree on substantial new decisions in high-risk areas and request the necessary permissions at the point of action.
- At each milestone, conduct a structural review: compare responsibilities, dependencies, and contracts with the previous map, assess added complexity and duplication, update ARCHITECTURE.md, and present the findings to the user for acceptance.

## High-risk areas

- `AudioEngine.swift`: audio output stability and real-time processing.
- `AudioDiscovery.swift`: changing the system output device.
