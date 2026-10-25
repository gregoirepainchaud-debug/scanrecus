// Généré depuis juge.py — la source Python du
// juge, que l'app écrit dans Application
// Support/ScanRecus/Juge en préparant l'atelier.
// Ne pas éditer à la main : régénérer depuis
// le script d'entraînement.
enum JugeScript {
    static let source = #"""
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Juge artificiel v0 — ScanReçus (hors-ligne, R&D).

But : mesurer, sur le BANC FIGÉ (photos jamais entraînées,
drapeau `bench` du journal), si un juge qui VOIT l'image peut
prédire les commentaires de Grégoire (−1 mal / 0 incertain /
+1 bien) mieux que :
  - le juge paresseux (toujours la classe majoritaire), et
  - un juge « géométrie seule » (k-NN sur descripteurs de
    polygones, sans image).

Entrées :
  - data/jeu-entrainement.jsonl : le journal du jeu du lasso.
  - data/banque-materiel.jsonl  : le manifeste de la banque.
  - un dossier d'images de la banque (les fichiers servis).

Protocole (hygiène anti-mémorisation) :
  - Tentatives avec fantôme et note dans {−1, 0, +1}.
    Depuis le build 123, les suggestions de Grégoire
    (ses formes corrigées, presque toujours notées +1)
    nourrissent l'ENTRAÎNEMENT : le juge apprend aussi
    à quoi ressemble un cadre jugé « bien » comme état.
    L'EXAMEN (banc) reste composé uniquement de
    propositions machine — c'est le vrai travail du
    juge qu'on y mesure.
  - Entraînement : tentatives bench = false UNIQUEMENT.
  - Bulletin : tentatives bench = true UNIQUEMENT, images
    telles que servies (aucune augmentation sur l'examen).
  - Augmentation (entraînement seulement) : translations et
    échelles légères, appliquées identiquement à l'image et
    aux deux polygones. Aucun flip (le texte des reçus n'est
    jamais miroir dans la vraie banque).

Sorties : bulletin imprimé + bulletin.json + juge-v0.pt.
"""
import argparse, json, math, os, random, sys, collections

import numpy as np
from PIL import Image, ImageDraw

try:
    from pillow_heif import register_heif_opener
    register_heif_opener()
except Exception as e:
    print(f"[avertissement] pillow-heif indisponible : {e}")

SIZE = 160
CLASSES = [-1, 0, 1]


def pts(poly):
    out = []
    for p in poly:
        if isinstance(p, dict):
            out.append((float(p["x"]), float(p["y"])))
        else:
            out.append((float(p[0]), float(p[1])))
    return out


def load_attempts(journal_path):
    attempts = []
    for line in open(journal_path):
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except Exception:
            continue
        if r.get("stage") != "lasso":
            continue
        if r.get("source") not in ("recherche", "sonde",
                                   "suggestion"):
            continue
        if r.get("ghost") is None:
            continue
        if r.get("rating") not in CLASSES:
            continue
        attempts.append({
            "file": r["file"],
            "ghost": pts(r["ghost"]),
            "cand": pts(r["lasso"]),
            "rating": int(r["rating"]),
            "bench": bool(r.get("bench")),
            "cycle": int(r.get("cycle", 0)),
            "source": r.get("source"),
        })
    return attempts


def render_sample(img_path, ghost, cand, jitter=None, rng=None):
    """Retourne un tenseur numpy (5, SIZE, SIZE) float32 :
    RGB + masque fantôme + masque candidat."""
    img = Image.open(img_path).convert("RGB")
    W, H = img.size
    g = [(x * W, y * H) for x, y in ghost]
    c = [(x * W, y * H) for x, y in cand]
    if jitter is not None:
        # Translation identique pour l'image et les deux
        # polygones : le jugement reste valide, seule la
        # position absolue change.
        dx = jitter[0] * W
        dy = jitter[1] * H
        img = img.transform(
            (W, H), Image.AFFINE, (1, 0, -dx, 0, 1, -dy),
            resample=Image.BILINEAR, fillcolor=(0, 0, 0))
        g = [(x + dx, y + dy) for x, y in g]
        c = [(x + dx, y + dy) for x, y in c]
    img = img.resize((SIZE, SIZE), Image.BILINEAR)
    scale = SIZE / W, SIZE / H
    def mask(poly):
        m = Image.new("F", (SIZE, SIZE), 0.0)
        d = ImageDraw.Draw(m)
        sp = [(x * scale[0], y * scale[1]) for x, y in poly]
        d.polygon(sp, fill=0.30)
        d.line(sp + [sp[0]], fill=1.0, width=2)
        return np.asarray(m, dtype=np.float32)
    rgb = np.asarray(img, dtype=np.float32) / 255.0
    rgb = np.transpose(rgb, (2, 0, 1))
    return np.stack([rgb[0], rgb[1], rgb[2],
                     mask(g), mask(c)]).astype(np.float32)


def build_resolver(racine):
    """file -> chemin local, en résolvant comme l'app :
    images/<file> à plat, sinon images/<sha[:2]>/<file>
    (fichiers du build 77 nommés par empreinte)."""
    import os as _os
    man = _os.path.join(racine, "banque.jsonl")
    sha_of = {}
    if _os.path.exists(man):
        for line in open(man):
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except Exception:
                continue
            e = r.get("photo") or r.get("derive") or {}
            if e.get("file") and e.get("sha256"):
                sha_of[e["file"]] = e["sha256"]
    def resolve(name):
        flat = _os.path.join(racine, "images", name)
        if _os.path.exists(flat):
            return flat
        sha = sha_of.get(name, "")
        if sha:
            alt = _os.path.join(racine, "images", sha[:2], name)
            if _os.path.exists(alt):
                return alt
        return flat
    return resolve


# ---------------- Données synthétiques (test fumée) ----
def synthetic_dataset(n=240, seed=7):
    rng = random.Random(seed)
    samples = []
    W = H = 400
    for i in range(n):
        img = Image.new("RGB", (W, H), (40, 40, 46))
        d = ImageDraw.Draw(img)
        cx, cy = rng.uniform(140, 260), rng.uniform(140, 260)
        w, h = rng.uniform(90, 150), rng.uniform(120, 190)
        ang = rng.uniform(-0.5, 0.5)
        def rot(x, y):
            return (cx + x * math.cos(ang) - y * math.sin(ang),
                    cy + x * math.sin(ang) + y * math.cos(ang))
        paper = [rot(-w / 2, -h / 2), rot(w / 2, -h / 2),
                 rot(w / 2, h / 2), rot(-w / 2, h / 2)]
        d.polygon(paper, fill=(235, 232, 225))
        for _ in range(6):
            y = rng.uniform(cy - h / 2 + 15, cy + h / 2 - 15)
            d.line([(cx - w / 2 + 12, y), (cx + w / 2 - 12, y)],
                   fill=(120, 120, 120), width=3)
        def jittered(base, amp):
            return [(x + rng.uniform(-amp, amp),
                     y + rng.uniform(-amp, amp)) for x, y in base]
        ghost = jittered(paper, 26)
        mode = rng.random()
        if mode < 0.45:
            cand = jittered(paper, 7)          # bien refermé
            rating = 1
        elif mode < 0.85:
            cand = jittered(paper, 55)         # mal cadré
            rating = -1
        else:
            cand = jittered(ghost, 12)         # incertain
            rating = 0
        path = f"/tmp/juge-smoke-{i}.png"
        img.save(path)
        norm = lambda poly: [(x / W, y / H) for x, y in poly]
        samples.append({"file": path, "ghost": norm(ghost),
                        "cand": norm(cand), "rating": rating,
                        "bench": i % 7 == 3, "cycle": 3,
                        "_path": path})
    return samples


# ---------------- Baselines -------------------------
def geom_features(a):
    def area(p):
        s = 0.0
        for i in range(len(p)):
            x1, y1 = p[i]
            x2, y2 = p[(i + 1) % len(p)]
            s += x1 * y2 - x2 * y1
        return abs(s) / 2
    def cen(p):
        return (sum(x for x, _ in p) / len(p),
                sum(y for _, y in p) / len(p))
    c, g = a["cand"], a["ghost"]
    cc, cg = cen(c), cen(g)
    return [math.log(max(1e-6, area(c)) / max(1e-6, area(g))),
            math.hypot(cc[0] - cg[0], cc[1] - cg[1]),
            len(c) - len(g), a["cycle"]]


def knn_predict(train, test, k=7):
    F = [geom_features(a) for a in train]
    mu = [np.mean([f[j] for f in F]) for j in range(len(F[0]))]
    sd = [np.std([f[j] for f in F]) or 1.0 for j in range(len(F[0]))]
    Z = [[(v - mu[j]) / sd[j] for j, v in enumerate(f)] for f in F]
    out = []
    for a in test:
        f = geom_features(a)
        z = [(v - mu[j]) / sd[j] for j, v in enumerate(f)]
        d = sorted((float(np.linalg.norm(np.array(Z[i]) - np.array(z))),
                    train[i]["rating"]) for i in range(len(train)))
        out.append(collections.Counter(l for _, l in d[:k])
                   .most_common(1)[0][0])
    return out


def metrics(y_true, y_pred):
    n = len(y_true)
    acc = sum(1 for t, p in zip(y_true, y_pred) if t == p) / n
    # kappa de Cohen
    po = acc
    pe = 0.0
    for cl in CLASSES:
        pe += (sum(1 for t in y_true if t == cl) / n) * \
              (sum(1 for p in y_pred if p == cl) / n)
    kappa = (po - pe) / (1 - pe) if pe < 1 else 0.0
    per = {}
    for cl in CLASSES:
        tot = sum(1 for t in y_true if t == cl)
        ok = sum(1 for t, p in zip(y_true, y_pred)
                 if t == cl and p == cl)
        per[cl] = (ok, tot)
    return acc, kappa, per


# ---------------- Entraînement ----------------------
DEVICE = "cpu"

def train_and_eval(train, test, resolve, epochs=40, seed=11,
                   smoke=False, sortie="."):
    import torch
    import torch.nn as nn
    torch.manual_seed(seed)
    rng = random.Random(seed)
    dev = torch.device(DEVICE)

    def path_of(a):
        return a.get("_path") or resolve(a["file"])

    print("PHASE préparation des exemples", flush=True)
    Xtr, ytr = [], []
    total_tr = max(1, len(train))
    for idx, a in enumerate(train):
        variants = [None, (0.02, -0.015), (-0.018, 0.022)]
        for j in variants:
            Xtr.append(render_sample(path_of(a), a["ghost"],
                                     a["cand"], jitter=j, rng=rng))
            ytr.append(CLASSES.index(a["rating"]))
        if idx % 5 == 0:
            print(f"PROGRES {int(15 * idx / total_tr)}",
                  flush=True)
    print("PROGRES 15", flush=True)
    Xte = []
    total_te = max(1, len(test))
    for idx, a in enumerate(test):
        Xte.append(render_sample(path_of(a), a["ghost"],
                                 a["cand"]))
        if idx % 5 == 0:
            print(f"PROGRES {15 + int(5 * idx / total_te)}",
                  flush=True)
    print("PROGRES 20", flush=True)
    yte = [CLASSES.index(a["rating"]) for a in test]
    Xtr = torch.tensor(np.stack(Xtr)).to(dev)
    ytr = torch.tensor(ytr).to(dev)
    Xte = torch.tensor(np.stack(Xte)).to(dev)

    class Net(nn.Module):
        def __init__(self):
            super().__init__()
            def blk(cin, cout):
                return nn.Sequential(
                    nn.Conv2d(cin, cout, 3, stride=2, padding=1),
                    nn.BatchNorm2d(cout), nn.ReLU(),
                    nn.Conv2d(cout, cout, 3, padding=1),
                    nn.BatchNorm2d(cout), nn.ReLU())
            self.body = nn.Sequential(blk(5, 32), blk(32, 64),
                                      blk(64, 128))
            self.head = nn.Sequential(
                nn.AdaptiveAvgPool2d(1), nn.Flatten(),
                nn.Linear(128, 64), nn.ReLU(),
                nn.Linear(64, 3))
        def forward(self, x):
            return self.head(self.body(x))

    net = Net().to(dev)
    counts = collections.Counter(ytr.tolist())
    w = torch.tensor([1.0 / counts.get(i, 1) for i in range(3)],
                     dtype=torch.float32).to(dev)
    w = w / w.mean()
    lossf = nn.CrossEntropyLoss(weight=w)
    opt = torch.optim.Adam(net.parameters(), lr=1e-3,
                           weight_decay=1e-4)
    n = len(Xtr)
    dernier = [20]
    for ep in range(epochs):
        print(f"PHASE époque {ep + 1}/{epochs}", flush=True)
        net.train()
        perm = torch.randperm(n)
        for i in range(0, n, 32):
            idx = perm[i:i + 32]
            opt.zero_grad()
            loss = lossf(net(Xtr[idx]), ytr[idx])
            loss.backward()
            opt.step()
            frac = (ep + (i + len(idx)) / n) / epochs
            pct = 20 + int(78 * frac)
            if pct >= dernier[0] + 2:
                dernier[0] = pct
                print(f"PROGRES {pct}", flush=True)
    net.eval()
    with torch.no_grad():
        pred = net(Xte).argmax(1).tolist()
    torch.save(net.state_dict(),
               os.path.join(sortie, "juge-modele.pt"))
    return [CLASSES[i] for i in pred]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--racine",
                    default=os.path.expanduser(
                        "~/Library/Application Support/"
                        "ScanRecus/Atelier"))
    ap.add_argument("--sortie", default=".")
    ap.add_argument("--epochs", type=int, default=40)
    ap.add_argument("--smoke", action="store_true")
    args = ap.parse_args()
    os.makedirs(args.sortie, exist_ok=True)

    global DEVICE
    try:
        import torch as _t
        DEVICE = ("mps" if _t.backends.mps.is_available()
                  else "cpu")
    except Exception:
        DEVICE = "cpu"
    print(f"appareil d'entraînement : {DEVICE}", flush=True)

    resolve = None
    if args.smoke:
        attempts = synthetic_dataset()
        print("MODE TEST FUMÉE — données synthétiques")
        resolve = lambda name: name
    else:
        attempts = load_attempts(os.path.join(
            args.racine, "jeu.jsonl"))
        resolve = build_resolver(args.racine)
    train = [a for a in attempts if not a["bench"]]
    test = [a for a in attempts
            if a["bench"]
            and a.get("source") != "suggestion"]
    n_sugg = sum(1 for a in train
                 if a.get("source") == "suggestion")
    print(f"suggestions incluses à l'entraînement : "
          f"{n_sugg}", flush=True)
    print(f"tentatives jugeables : {len(attempts)} "
          f"(entraînement {len(train)} · banc {len(test)})")
    print(f"distribution entraînement : "
          f"{collections.Counter(a['rating'] for a in train)}")
    print(f"distribution banc : "
          f"{collections.Counter(a['rating'] for a in test)}")
    if len(test) < 5 or len(train) < 20:
        print("Pas assez de données pour un bulletin honnête.")
        return 1

    y_true = [a["rating"] for a in test]
    majority = collections.Counter(
        a["rating"] for a in train).most_common(1)[0][0]
    lazy = [majority] * len(test)
    acc_l, kap_l, _ = metrics(y_true, lazy)
    pred_knn = knn_predict(train, test)
    acc_k, kap_k, _ = metrics(y_true, pred_knn)
    pred_net = train_and_eval(train, test, resolve,
                              epochs=args.epochs,
                              smoke=args.smoke,
                              sortie=args.sortie)
    acc_n, kap_n, per = metrics(y_true, pred_net)

    print("PROGRES 100", flush=True)
    print("\n===== BULLETIN DU JUGE — BANC FIGÉ (jamais entraîné) =====")
    print(f"juge paresseux (toujours {majority:+d}) : "
          f"accord {acc_l:.0%} · kappa {kap_l:.2f}")
    print(f"juge géométrie seule (k-NN)      : "
          f"accord {acc_k:.0%} · kappa {kap_k:.2f}")
    print(f"juge v0 (voit l'image)           : "
          f"accord {acc_n:.0%} · kappa {kap_n:.2f}")
    for cl in CLASSES:
        ok, tot = per[cl]
        print(f"  classe {cl:+d} : {ok}/{tot} retrouvées")
    import datetime
    out = {"appareil": DEVICE,
           "genere": datetime.datetime.now().isoformat(
               timespec="seconds"),
           "n_train": len(train), "n_bench": len(test),
           "n_suggestions": n_sugg,
           "lazy": {"acc": acc_l, "kappa": kap_l},
           "knn_geom": {"acc": acc_k, "kappa": kap_k},
           "juge_v0": {"acc": acc_n, "kappa": kap_n,
                       "per_class": {str(k): v for k, v in per.items()}}}
    with open(os.path.join(args.sortie, "bulletin.json"),
              "w") as f:
        json.dump(out, f, indent=2, ensure_ascii=False)
    print("\nbulletin.json écrit.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
"""#
}
