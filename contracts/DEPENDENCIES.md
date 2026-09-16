# Contract dependencies

Dependencies are pinned as Git submodules and mirrored in `toolchain.lock.json`.
Production builds must use the recorded commits; tags alone are not a lock.

| Dependency | Version | Commit | License |
| --- | --- | --- | --- |
| OpenZeppelin Contracts | 5.6.1 | `5fd1781b1454fd1ef8e722282f86f9293cacf256` | MIT |
| OpenZeppelin Contracts Upgradeable | 5.6.1 | `7bf4727aacdbfaa0f36cbd664654d0c9e1dc52bf` | MIT |
| forge-std | 1.16.2 | `bf647bd6046f2f7da30d0c2bf435e5c76a780c1b` | MIT OR Apache-2.0 |

OpenZeppelin includes vendored Compound interfaces under
`contracts/vendor/compound`; those files retain the Compound Labs
BSD-3-Clause license in both OpenZeppelin submodules.

License texts are retained in each submodule:

- `lib/openzeppelin-contracts/LICENSE`
- `lib/openzeppelin-contracts-upgradeable/LICENSE`
- `lib/openzeppelin-contracts/contracts/vendor/compound/LICENSE`
- `lib/openzeppelin-contracts-upgradeable/contracts/vendor/compound/LICENSE`
- `lib/forge-std/LICENSE-MIT`
- `lib/forge-std/LICENSE-APACHE`

To restore exactly the recorded dependencies after checkout:

```bash
git submodule sync --recursive
git submodule update --init --recursive
npm run toolchain:check
```

Changing a dependency requires updating the Git submodule, this file,
`toolchain.lock.json`, reproducibility evidence, and the security review.
