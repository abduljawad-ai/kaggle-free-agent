# kaggle-free-agent

Run a **free, uncensored 27B coding model on Kaggle** and use it from **OpenCode**
(or **jcode**, or any OpenAI-compatible tool) on your own machine — from **any folder**.

No cloud API keys, no credit card. The model runs on Kaggle's free GPUs; your PC
just talks to it through a free [zrok](https://zrok.io) tunnel.

```
[Kaggle]  kaggle_cell.py  ->  llama-server (Qwen3.8-27B abliterated) + sshd + zrok tunnel
                                          |
[your PC] ./connect.sh <SHARE_TOKEN>  ->  tunnel + port-forward + registers the model
                                          |
[your PC] opencode / jcode  ->  model appears in the list, in ANY folder
```

## Files

| File | Runs on | What it is |
|---|---|---|
| `setup.sh` | your PC | **One-time:** creates your SSH key and prints the public key. |
| `kaggle_cell.py` | Kaggle | The **only** Kaggle cell — downloads the model, starts `llama-server`, opens sshd + a zrok tunnel, prints the SHARE TOKEN. |
| `connect.sh` | your PC | The **one command** per session — builds the tunnel, forwards the model to `127.0.0.1:8080`, and registers it in OpenCode + jcode. |
| `optional/way2_setup.sh` | Kaggle | Only if you want to run OpenCode *inside* Kaggle. Not needed normally. |

## Requirements

- **On Kaggle:** a free account. A phone-verified account is required for GPU + Internet.
- **On your PC:** Linux or macOS (Windows: use WSL), with `bash`, `ssh`, `python3`, `curl`.
- **A free zrok account:** sign up at **https://myzrok.io** (not zrok.io).
  Sign in → zrok icon in the left sidebar → green **CLICK HERE TO GET STARTED!**
  → step 2 shows your account token.

## One-time setup

**1. Create your SSH key (on your PC):**
```bash
cd kaggle-free-agent
./setup.sh
```
It prints your **public key**. Copy it.

**2. Add two secrets on Kaggle** (notebook → **Add-ons → Secrets**):
| Secret | Value |
|---|---|
| `SSH_PUBKEY` | the public key printed by `setup.sh` |
| `ZROK_TOKEN` | your account token from https://myzrok.io |

**3. Kaggle notebook settings:** accelerator **GPU T4 ×2**, **Internet ON**.

## Run it (every session)

**Step 1 — Kaggle:** paste `kaggle_cell.py` into one cell and run it.
Wait for:
```
ZROK SHARE TOKEN = xxxxxxxxxxxx

  >>> On your PC, run this ONE command:
        ./connect.sh xxxxxxxxxxxx
```
**Leave that cell running** — it blocks on purpose to hold the tunnel open.

**Step 2 — your PC:**
```bash
cd kaggle-free-agent
./connect.sh <SHARE_TOKEN>
```
Wait for `READY`.

**Step 3 — use it anywhere:**
```bash
opencode                                 # → /models → Kaggle Local / qwen3.8-27b-rvn
jcode --provider-profile kaggle          # jcode, same model
```

Anything OpenAI-compatible works too — the endpoint is just
`http://127.0.0.1:8080/v1`, model `qwen3.8-27b-rvn`.

## Notes

- The first reply is slow (~25 s): OpenCode sends a ~7,500-token system prompt at
  ~310 tok/s prefill; generation then runs ~15–20 tok/s on the free T4s.
- Kaggle's free GPU quota is **per account** (≈30 h/week), not per device.
  To switch accounts: new Kaggle account (with its own phone verification),
  add the **same** `ZROK_TOKEN` + `SSH_PUBKEY` secrets, run the cell, and
  `./connect.sh <new-share-token>`. Your PC side never changes.
- Only one Kaggle cell at a time (it blocks by design).

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Connection refused` on the PC | Kaggle cell stopped, or the token is stale. Re-run the cell → new token → `./connect.sh <token>`. |
| `SSH test failed` | Tunnel still warming up, or wrong share token. Re-run `./connect.sh <token>`. |
| `Missing secret ZROK_TOKEN` on Kaggle | Add the `ZROK_TOKEN` secret (Add-ons → Secrets) and re-run. |
| `No SSH public key` on Kaggle | Run `./setup.sh`, then add the `SSH_PUBKEY` secret (or paste it into `PUBKEY` in the cell). |
| Model offline in OpenCode | Re-run `./connect.sh <token>` (the forward dropped). |

## License

MIT — see [LICENSE](LICENSE).
