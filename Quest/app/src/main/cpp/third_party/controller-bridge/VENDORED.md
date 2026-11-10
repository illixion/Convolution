# Controller Bridge pairing maths (vendored)

Copied from Controller Bridge (`illixion/controller-bridge`, the Quest
controller streamer) at commit `ad9aa13f142f9a9612764c97697c695eb3e97171`, `protocol/`:

- `qcb_crypto.c`, `qcb_crypto.h`: SHA-256, HMAC, HKDF and the headset's side of
  RAVECompanion v2 pairing (`qcb_pair_commitment_v2` / `qcb_pair_agree_v2`,
  with Vergence's `"Vergence"` label prefix), plus CryptoKit's ChaChaPoly box.
- `quest_bridge_protocol.h`: included by `qcb_crypto.h` for its sizes.
- `third_party/monocypher/`: X25519 and ChaCha20-Poly1305 (BSD-2 or CC0, see
  `LICENCE.md`).

These are a copy, not a path reference to the sibling checkout, so a Hypnos
clone (and an `apple-worktree`) builds without Controller Bridge beside it.
Change them upstream first, run its `protocol/tests/run.sh`, then copy the files
again and update the commit above. Convolution's own tests of the copy are in
`Quest/native-tests/` (the Vergence vectors come from vergence-companion, the
Rust port the coordinator uses).
