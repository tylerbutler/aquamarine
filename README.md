# Aquamarine

Aquamarine is the protocol-agnostic Beryl-style channel client runtime for Gleam.
It provides the client runtime layer while protocol packages supply codecs.

For Phoenix and Beryl compatibility, configure Aquamarine with `aquamarine/phoenix.codec()`.

## Topicless protocols

Set `Codec.topicless_events` to `True` for protocols whose event frames have no
topic. Aquamarine routes an empty-topic event to the socket's sole channel and
rejects a second topic with `TopiclessSocketOccupied`, including while the first
join is pending. Close and error events remove that channel from reconnect state.
They also fail its pending calls. Aquamarine drops stale referenced replies for
topicless codecs so an earlier join cannot close a replacement channel.

Decode heartbeat replies with a distinct, nonempty `heartbeat_topic`; Aquamarine
does not forward them to the channel. Codecs that route by topic, including
Phoenix, must set the new `topicless_events` field to `False`.

## Quick start

```gleam
import aquamarine
import aquamarine/phoenix
import gleam/json

let assert Ok(channel) =
  aquamarine.connect(
    host: "localhost",
    port: 4000,
    path: "/socket/websocket",
    topic: "room:lobby",
    payload: json.object([]),
    codec: phoenix.codec(),
  )
```

## Releases

Aquamarine uses Trellis, pinned in `.mise.toml`, for Git-only releases. It creates
immutable `v{version}` tags and GitHub Releases with changelog notes. It does not
publish to Hex. Run `mise install` to install the local tools.

For a user-facing change, run
`just change --kind Fixed --body "Describe the change"` (with the correct kind)
and commit the generated fragment.
Development-only changes do not need a fragment. Use `just changelog-preview`
and `just tag-plan` for read-only previews.

Pushes to `main` create or update a `release/pending` PR. Trellis preserves its
target version and release mode. During an RC cycle, new release content prepares
the next candidate; unchanged content does not create another candidate.
Automatic preparation never promotes an RC to stable.

To start a candidate cycle, run the **Trellis Release** workflow on **main** with
`action: prepare`, `pre: rc`, and an optional target `version`, such as `0.2.0`.
To promote it, dispatch `action: prepare` with `pre: none`. Blank inputs preserve
the pending request or current candidate mode. The local equivalent is
`just release-pr --pre rc --set aquamarine=0.2.0`; it writes a remote release PR.
Commit native `.changes/release.toml` intent and candidate archives with the
release changes when preparing them locally.

Review and merge the release PR through normal required checks. Only a merged
`release/pending` PR from this repository targeting `main` creates tags and
GitHub Releases. The workflow uses that PR's exact merge commit, not current
`main`. RC GitHub Releases are marked as prereleases. Tag pushes run CI checks.

If tagging or GitHub Release creation fails, rerun the merge-triggered workflow,
or dispatch **Trellis Release** on **main** with `action: recover` and the merged
`release_pr` number. Recovery verifies the PR and uses its approved merge commit,
even if `main` has advanced. Existing tags/releases are reconciled by Trellis;
conflicts fail rather than retarget immutable tags. `just tag` also writes tags
and GitHub Releases and must only run at an approved release merge.

### Repository setup

Install a GitHub App on this repository with **Contents** and **Pull requests**
read/write permissions. Add its ID and private key as repository Actions secrets
`RELEASE_APP_ID` and `RELEASE_APP_PRIVATE_KEY`. The workflow requests only the
permissions each job needs. App-token writes allow release PR and tag pushes to
trigger normal CI; the default Actions token would suppress those workflows.
No Hex key is needed.

Protect `main` with required reviews and CI checks, including for release PRs.
Restrict writes to `release/pending` and who can dispatch releases. A merge of
that same-repository branch is the authorization to release. These settings and
secrets must be configured separately; adding the workflows does not set them.
