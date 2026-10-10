# ============================================================================
#  KAGGLE CELL  —  the ONLY Kaggle cell for this setup.
#  Paste this whole file into ONE Kaggle notebook cell and run it.
#
#  It does, in order:
#    1) download the model (if missing) + the llama-server binary
#    MODEL: MTP=True -> Qwen3.8-27B IQ4 MTP. MTP=False -> 9B Q4_K_M.
#    2) start llama-server on 127.0.0.1:8080
#    3) set up sshd on Kaggle + install YOUR PC's SSH public key
#    4) open a zrok private TCP tunnel to sshd and print the SHARE TOKEN
#    5) block forever to keep the tunnel alive  (this is normal — leave it running)
#
#  REQUIRED Kaggle secrets (Add-ons > Secrets):
#    ZROK_TOKEN = account token from https://myzrok.io
#    SSH_PUBKEY = the PUBLIC key of your PC  (run ./setup.sh to create/print it)
#
#  NEXT: on your PC, run  ./connect.sh <SHARE_TOKEN>   (ONE command)
# ============================================================================
import os, subprocess, threading, time, sys, re, socket, requests
os.chdir("/kaggle/working")

# ---- model choice: False = 9B Q4_K_M (this folder) ; True = 27B MTP -------
MTP = True   # True -> real 27B IQ4 MTP | False -> 9B Q4_K_M
if MTP:
    REPO, FILE = "finex666/Qwen3.8-27B-Abliterated-IQ4-MIX-MTP-GGUF", "Qwen3.8-27B-Abliterated-IQ4-MIX-MTP.gguf"
else:
    REPO, FILE = "MegaPanchamZ/Qwen3.8-9B-abliterated-25-GGUF", "Qwen3.8-9B-abliterated-25.Q4_K_M.gguf"

# ---- your PC's SSH public key ---------------------------------------------
# Put YOUR OWN public key here, OR (recommended) set a Kaggle Secret named
# SSH_PUBKEY with it. Run ./setup.sh on your PC to create/print your key.
# NEVER paste someone else's key here.
PUBKEY = "PASTE_YOUR_PUBLIC_KEY_HERE"

ZROK_TOKEN = None
try:
    from kaggle_secrets import UserSecretsClient
    _secrets = UserSecretsClient()
    ZROK_TOKEN = _secrets.get_secret("ZROK_TOKEN")
    try:
        _pk = (_secrets.get_secret("SSH_PUBKEY") or "").strip()
        if _pk:
            PUBKEY = _pk
    except Exception:
        pass
except Exception:
    pass

if not ZROK_TOKEN:
    sys.exit("Missing secret ZROK_TOKEN (from https://myzrok.io)")
if "PASTE_YOUR_PUBLIC_KEY_HERE" in PUBKEY or not PUBKEY.strip():
    sys.exit("No SSH public key. Run ./setup.sh on your PC and add a Kaggle secret "
             "named SSH_PUBKEY with the printed key (or paste it into PUBKEY above).")

def run(cmd, quiet=False):
    print("==>", str(cmd)[:100], flush=True)
    return subprocess.run(cmd, shell=True, check=False,
        stdout=subprocess.DEVNULL if quiet else None,
        stderr=subprocess.STDOUT if quiet else None, text=True)

def server_up():
    try:
        return requests.get("http://127.0.0.1:8080/health", timeout=2).status_code == 200
    except Exception:
        return False

# ---- 1) model -------------------------------------------------------------
os.makedirs("/kaggle/working/models", exist_ok=True)
MODEL_PATH = "/kaggle/working/models/" + FILE
if not os.path.exists(MODEL_PATH):
    print("downloading", FILE, "...")
    from huggingface_hub import hf_hub_download
    hf_hub_download(repo_id=REPO, filename=FILE, local_dir="/kaggle/working/models")
print("model ok:", f"{os.path.getsize(MODEL_PATH)/1e9:.1f} GB")

# ---- 2) llama-server ------------------------------------------------------
if not os.path.exists("./cuda-12.8/llama-server"):
    run("wget -q https://github.com/ai-dock/llama.cpp-cuda/releases/download/v0.6.0/llama.cpp-v0.6.0-cuda-12.8-amd64.tar.gz")
    run("tar -xzf llama.cpp-v0.6.0-cuda-12.8-amd64.tar.gz && rm llama.cpp-v0.6.0-cuda-12.8-amd64.tar.gz")
run("chmod +x ./cuda-12.8/llama-server")

if not server_up():
    env = os.environ.copy()
    env["LD_LIBRARY_PATH"] = "/kaggle/working/cuda-12.8:" + env.get("LD_LIBRARY_PATH", "")
    cmd = ["./cuda-12.8/llama-server", "--model", MODEL_PATH, "-ngl", "999", "--split-mode", "layer",
           "--ctx-size", "131072", "--parallel", "1", "--n-predict", "-1",
           "--cache-type-k", "q8_0", "--cache-type-v", "q8_0",
           "-b", "512", "-ub", "256", "--jinja", "--reasoning-format", "deepseek",
           "--flash-attn", "on", "--alias", "qwen3.8-27b-rvn", "--host", "127.0.0.1", "--port", "8080"]
    if MTP:
        cmd += ["--spec-type", "draft-mtp", "--spec-draft-n-max", "3"]
    with open("llama-server.log", "w") as f:
        subprocess.Popen(cmd, stdout=f, stderr=subprocess.STDOUT, env=env)
    for _ in range(120):
        if server_up():
            break
        time.sleep(1)
print("llama-server up:", server_up())

# ---- 3) sshd + your key ---------------------------------------------------
run("apt-get update -qq && apt-get install -y -qq openssh-server >/dev/null 2>&1", quiet=True)
run("mkdir -p /root/.ssh && chmod 700 /root/.ssh")
open("/root/.ssh/authorized_keys", "w").write(PUBKEY.strip() + "\n")
run("chmod 600 /root/.ssh/authorized_keys && chown -R root:root /root/.ssh")
p = "/etc/ssh/sshd_config"
orig = open(p).read().splitlines()
wanted = ["PermitRootLogin yes", "PubkeyAuthentication yes", "PasswordAuthentication yes",
          "KbdInteractiveAuthentication no", "UsePAM no"]
pat = re.compile(r"^\s*(PermitRootLogin|PubkeyAuthentication|PasswordAuthentication|UsePAM|"
                 r"KbdInteractiveAuthentication|ChallengeResponseAuthentication|AuthenticationMethods)\b", re.I)
open(p, "w").write("\n".join(wanted + [l for l in orig if not pat.match(l)]) + "\n")
run("mkdir -p /run/sshd && chmod 0755 /run/sshd")
run("ssh-keygen -A")
run("pkill -x sshd || true", quiet=True)
run("sleep 1")
run("/usr/sbin/sshd -t && /usr/sbin/sshd")
run("sleep 2")
SSHD_PORT = None
for port in (22, 2222, 2022, 2200):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(2)
    try:
        s.connect(("127.0.0.1", port))
        b = s.recv(64)
        if b.startswith(b"SSH-"):
            SSHD_PORT = port
            print(f"sshd on 127.0.0.1:{port}")
            break
    except Exception:
        pass
    finally:
        s.close()
if not SSHD_PORT:
    sys.exit("no sshd found on 22/2222/2022/2200")

# ---- 4) zrok tunnel -------------------------------------------------------
Z = "/kaggle/working/zrok2"
if not os.path.exists(Z):
    run("curl -sSL https://github.com/openziti/zrok/releases/download/v2.0.8/zrok_2.0.8_linux_amd64.tar.gz -o /tmp/zrok.tgz && tar -xzf /tmp/zrok.tgz -C /kaggle/working zrok2 && chmod +x /kaggle/working/zrok2")
run(f"{Z} config set apiEndpoint https://api-v2.zrok.io")
if not os.path.exists(os.path.expanduser("~/.zrok2/environment.json")):
    run(f"{Z} enable {ZROK_TOKEN} --headless")
else:
    print("zrok env already enabled")

proc = subprocess.Popen([Z, "share", "private", "--backend-mode", "tcpTunnel",
                         "--open", "--headless", f"localhost:{SSHD_PORT}"],
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
lines = []
def reader():
    for line in proc.stdout:
        lines.append(line.rstrip())
        print(line, end="", flush=True)
threading.Thread(target=reader, daemon=True).start()
token = None
t0 = time.time()
while time.time() - t0 < 90:
    time.sleep(1)
    m = re.search(r"access private[:\s]+([A-Za-z0-9_-]+)", "\n".join(lines))
    if m:
        token = m.group(1)
        break
if not token:
    print("could not read share token")
    proc.terminate()
    sys.exit(1)

print("\n" + "=" * 60)
print("  ZROK SHARE TOKEN = " + token)
print("")
print("  >>> On your PC, run this ONE command:")
print("        ./connect.sh " + token)
print("")
print("  Then open  opencode  in ANY folder and pick:")
print("        Kaggle Local / qwen3.8-27b-rvn")
print("=" * 60)
print("Leave this cell running.\n")

# ---- 5) keep alive --------------------------------------------------------
try:
    while True:
        time.sleep(60)
except KeyboardInterrupt:
    proc.terminate()
