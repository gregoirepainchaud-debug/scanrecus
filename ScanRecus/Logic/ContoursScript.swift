import Foundation

/// Source Python du traceur de contours (v0),
/// embarquée dans l'app et écrite dans l'atelier
/// à chaque lancement — générée depuis
/// contours.py, NE PAS éditer ici.
enum ContoursScript {
    static let source = #"""
# contours.py — Traceur v0 : premier réseau de
# contours de ScanReçus (build 133, 2026-10-25).
#
# LE TEST DÉCISIF, demandé par Grégoire : est-ce
# qu'un réseau peut apprendre SES contours de
# reçus à partir de ses seuls tracés finis (les
# élites +2 du journal) ? Aucune note −1/0/+1
# n'entre ici : on enseigne des DESTINATIONS,
# pas une procédure (sa conclusion du
# 2026-10-25 au soir).
#
# Principe : petit U-Net de segmentation
# (image -> masque du reçu), entraîné sur les
# paires (image servie, polygone d'élite) du
# journal jeu.jsonl, avec augmentation par
# rotations (image et masque tournés ensemble ;
# jamais de miroir). Évaluation sur des photos
# JAMAIS entraînées :
#   - « banc de fortune » : photos d'entraînement
#     mises de côté par la règle 1 sur 7 — des
#     photos nouvelles, mais des reçus déjà vus ;
#   - le vrai banc figé (1 photo sur 7 par
#     groupe + groupe strict), dont les élites
#     sont encore rares : rapporté à part, sans
#     conclure dessus.
# Comparaison décisive : la BOÎTE NEUTRE
# (18 %-82 %), la « première proposition »
# actuelle du jeu. Métriques : erreur de contour
# (distance de Chamfer symétrique entre les
# bords des masques, en % de la diagonale) et
# IoU des masques.
#
# Protocole identique au juge : lignes
# « PROGRES n » (100 seulement si le bulletin
# est écrit), « PHASE ... », journal en clair.
# Sorties : bulletin-contours.json +
# contours-v0.pt dans --sortie.
# Aucune donnée ne sort du Mac.

import argparse
import json
import math
import os
import sys

import numpy as np

try:
    from PIL import Image, ImageDraw, ImageFilter
except Exception:
    Image = None

try:
    from pillow_heif import register_heif_opener
    register_heif_opener()
except Exception:
    print("[avertissement] pillow-heif indisponible",
          flush=True)

SIZE = 256
NEUTRAL = (0.18, 0.82)  # boîte neutre du jeu


# ---------------- Banque / journal ----------------

def bench_sets(racine):
    """(photos du banc par photo, photos de
    l'examen strict) depuis le manifeste de la
    banque. Banc par photo : dans chaque groupe,
    les photos d'indice %7 == 3 (triées par
    numéro). Examen strict : le ou les groupes
    d'indice %7 == 3 dans la liste triée des
    groupes (le découpage historique)."""
    man = os.path.join(racine, "banque.jsonl")
    photos = {}
    if not os.path.exists(man):
        return set(), set()
    for line in open(man):
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except Exception:
            continue
        if r.get("type") == "photo":
            e = r["photo"]
            photos[e["number"]] = e["group"]
    by_group = {}
    for n, g in photos.items():
        by_group.setdefault(g, []).append(n)
    bench = set()
    for ns in by_group.values():
        for i, n in enumerate(sorted(ns)):
            if i % 7 == 3:
                bench.add(n)
    groups = sorted(by_group)
    strict_groups = {g for i, g in enumerate(groups)
                     if i % 7 == 3}
    strict = {n for n, g in photos.items()
              if g in strict_groups}
    return bench, strict


def build_resolver(racine):
    """file -> chemin local, en résolvant comme
    l'app : images/<file> à plat, sinon
    images/<sha[:2]>/<file> (fichiers du build
    77 nommés par empreinte)."""
    man = os.path.join(racine, "banque.jsonl")
    sha_of = {}
    if os.path.exists(man):
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
        flat = os.path.join(racine, "images", name)
        if os.path.exists(flat):
            return flat
        sha = sha_of.get(name, "")
        if sha:
            alt = os.path.join(racine, "images",
                                sha[:2], name)
            if os.path.exists(alt):
                return alt
        return flat
    return resolve


def load_elites(journal_path):
    """Les élites du journal : un tracé fini par
    ligne lasso-elite (fichier servi + polygone
    en coordonnées normalisées de l'image
    servie)."""
    out = []
    if not os.path.exists(journal_path):
        return out
    for line in open(journal_path):
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except Exception:
            continue
        if r.get("stage") != "lasso-elite":
            continue
        lasso = r.get("lasso") or []
        if len(lasso) < 4:
            continue
        out.append({
            "file": r.get("file"),
            "sn": r.get("sourceNumber"),
            "lasso": [(float(p[0]), float(p[1]))
                      for p in lasso],
        })
    # Dernière élite par fichier (build 136) : le
    # mode Révision du jeu ajoute une nouvelle
    # ligne pour le même fichier servi — c'est
    # elle qui fait foi, l'ancienne est remplacée
    # (le journal, lui, garde tout).
    par_fichier = {}
    for e in out:
        par_fichier[e["file"]] = e
    return list(par_fichier.values())


# ---------------- Images / masques ----------------

def load_image_256(path):
    img = Image.open(path).convert("RGB")
    return img.resize((SIZE, SIZE), Image.BILINEAR)


def rasterize(lasso, size=SIZE):
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    d.polygon([(x * size, y * size) for x, y in lasso],
              fill=255)
    return m


def neutral_mask(size=SIZE):
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    d.rectangle([NEUTRAL[0] * size, NEUTRAL[0] * size,
                 NEUTRAL[1] * size, NEUTRAL[1] * size],
                fill=255)
    return m


# ---------------- Métriques ----------------

def iou(a, b):
    a = a > 0
    b = b > 0
    inter = np.logical_and(a, b).sum()
    union = np.logical_or(a, b).sum()
    return float(inter / union) if union else 0.0


def _edges(mask_bool):
    m = Image.fromarray(
        (mask_bool * 255).astype(np.uint8))
    er = m.filter(ImageFilter.MinFilter(3))
    e = mask_bool & ~(np.array(er) > 0)
    return np.argwhere(e).astype(np.float64)


def chamfer_pct(pred, true):
    """Distance moyenne symétrique entre les
    bords des deux masques, en % de la
    diagonale de l'image."""
    ep = _edges(pred > 0)
    et = _edges(true > 0)
    if len(ep) == 0 or len(et) == 0:
        return 100.0

    def mean_min(a, b):
        tot = 0.0
        for i in range(0, len(a), 512):
            chunk = a[i:i + 512]
            d = np.sqrt(
                ((chunk[:, None, :] - b[None, :, :])
                 ** 2).sum(-1))
            tot += float(d.min(1).sum())
        return tot / len(a)

    px = (mean_min(ep, et) + mean_min(et, ep)) / 2
    return px / (SIZE * math.sqrt(2)) * 100


# ---------------- Modèle ----------------

def build_model(torch):
    import torch.nn as nn
    import torch.nn.functional as F

    class UNet(nn.Module):
        def __init__(self, base=32):
            super().__init__()

            def blk(cin, cout):
                return nn.Sequential(
                    nn.Conv2d(cin, cout, 3, padding=1),
                    nn.GroupNorm(8, cout),
                    nn.ReLU(inplace=True),
                    nn.Conv2d(cout, cout, 3, padding=1),
                    nn.GroupNorm(8, cout),
                    nn.ReLU(inplace=True))

            self.d1 = blk(3, base)
            self.d2 = blk(base, base * 2)
            self.d3 = blk(base * 2, base * 4)
            self.pool = nn.MaxPool2d(2)
            self.u2 = blk(base * 4 + base * 2, base * 2)
            self.u1 = blk(base * 2 + base, base)
            self.out = nn.Conv2d(base, 1, 1)

        def forward(self, x):
            a = self.d1(x)
            b = self.d2(self.pool(a))
            c = self.d3(self.pool(b))
            u = F.interpolate(
                c, scale_factor=2, mode="bilinear",
                align_corners=False)
            u = self.u2(torch.cat([u, b], 1))
            u = F.interpolate(
                u, scale_factor=2, mode="bilinear",
                align_corners=False)
            u = self.u1(torch.cat([u, a], 1))
            return self.out(u)

    return UNet()


# ---------------- Données ----------------

def build_dataset(elites, resolve, rng, rotations=11):
    """(X uint8 [N,256,256,3], Y uint8 [N,256,256])
    : chaque élite en native + `rotations`
    variantes tournées (image et masque ensemble,
    jamais de miroir)."""
    xs, ys = [], []
    for i, e in enumerate(elites):
        path = resolve(e["file"])
        try:
            img = load_image_256(path)
        except Exception:
            print(f"image illisible, élite ignorée : "
                  f"{e['file']}", flush=True)
            continue
        msk = rasterize(e["lasso"])
        xs.append(np.asarray(img, dtype=np.uint8))
        ys.append(np.asarray(msk, dtype=np.uint8))
        for _ in range(rotations):
            ang = float(rng.uniform(-180, 180))
            xs.append(np.asarray(
                img.rotate(ang, resample=Image.BILINEAR,
                           fillcolor=(0, 0, 0)),
                dtype=np.uint8))
            ys.append(np.asarray(
                msk.rotate(ang, resample=Image.NEAREST,
                           fillcolor=0),
                dtype=np.uint8))
        print(f"PROGRES {5 + int(13 * (i + 1) / max(1, len(elites)))}",
              flush=True)
    return (np.stack(xs) if xs else None,
            np.stack(ys) if ys else None)


def synthetic_dataset(rng, n_train=36, n_dev=6):
    """Test fumée : rectangles clairs tournés sur
    fond sombre bruité — aucun fichier requis."""
    def make(n):
        xs, ys, polys = [], [], []
        for _ in range(n):
            w = rng.uniform(0.35, 0.6)
            h = rng.uniform(0.45, 0.75)
            cx, cy = 0.5, 0.5
            ang = math.radians(rng.uniform(-180, 180))
            pts = []
            for dx, dy in [(-w / 2, -h / 2), (w / 2, -h / 2),
                           (w / 2, h / 2), (-w / 2, h / 2)]:
                rx = dx * math.cos(ang) - dy * math.sin(ang)
                ry = dx * math.sin(ang) + dy * math.cos(ang)
                pts.append((cx + rx, cy + ry))
            m = Image.new("L", (SIZE, SIZE), 0)
            ImageDraw.Draw(m).polygon(
                [(x * SIZE, y * SIZE) for x, y in pts],
                fill=255)
            base = Image.new("RGB", (SIZE, SIZE),
                             (30, 30, 34))
            rec = Image.new("RGB", (SIZE, SIZE),
                            (215, 210, 195))
            base.paste(rec, (0, 0), m)
            noise = rng.normal(0, 6, (SIZE, SIZE, 1))
            arr = np.clip(
                np.asarray(base).astype(np.float64)
                + noise, 0, 255).astype(np.uint8)
            xs.append(arr)
            ys.append(np.asarray(m, dtype=np.uint8))
            polys.append(pts)
        return xs, ys, polys
    xtr, ytr, _ = make(n_train)
    xdv, ydv, pdv = make(n_dev)
    train = (np.stack(xtr), np.stack(ytr))
    dev = [{"img": Image.fromarray(xdv[i]),
            "lasso": pdv[i], "sn": -1}
           for i in range(n_dev)]
    return train, dev


# ---------------- Entraînement ----------------

def train_and_eval(train_xy, dev_items, banc_items,
                   resolve, epochs, seed=13,
                   strict_items=None):
    import torch
    import torch.nn.functional as Fn

    if torch.backends.mps.is_available():
        device = torch.device("mps")
    elif torch.cuda.is_available():
        device = torch.device("cuda")
    else:
        device = torch.device("cpu")
    print(f"appareil : {device}", flush=True)

    torch.manual_seed(seed)
    X, Y = train_xy
    n = len(X)
    print(f"exemples d'entraînement (augmentés) : {n}",
          flush=True)
    model = build_model(torch).to(device)
    opt = torch.optim.AdamW(model.parameters(),
                            lr=1e-3, weight_decay=1e-4)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(
        opt, T_max=max(1, epochs))
    bce = torch.nn.BCEWithLogitsLoss()

    def dice_loss(logits, y):
        p = torch.sigmoid(logits)
        inter = (p * y).sum(dim=(1, 2, 3))
        tot = p.sum(dim=(1, 2, 3)) + y.sum(dim=(1, 2, 3))
        return 1 - ((2 * inter + 1) / (tot + 1)).mean()

    rng = np.random.default_rng(seed)
    batch = 16
    for ep in range(epochs):
        model.train()
        order = rng.permutation(n)
        tot_loss = 0.0
        for i in range(0, n, batch):
            idx = order[i:i + batch]
            xb = torch.from_numpy(
                X[idx].astype(np.float32) / 255.0
            ).permute(0, 3, 1, 2).to(device)
            yb = torch.from_numpy(
                (Y[idx] > 0).astype(np.float32)
            ).unsqueeze(1).to(device)
            opt.zero_grad()
            logits = model(xb)
            loss = bce(logits, yb) + dice_loss(logits, yb)
            loss.backward()
            opt.step()
            tot_loss += float(loss.item()) * len(idx)
        sched.step()
        pct = 20 + int(76 * (ep + 1) / max(1, epochs))
        print(f"PROGRES {pct}", flush=True)
        print(f"époque {ep + 1}/{epochs} — perte "
              f"{tot_loss / n:.4f}", flush=True)

    model.eval()

    def predict_mask(img_pil):
        x = torch.from_numpy(
            np.asarray(img_pil, dtype=np.float32)
            / 255.0).permute(2, 0, 1).unsqueeze(0).to(device)
        with torch.no_grad():
            prob = torch.sigmoid(model(x))[0, 0]
        return (prob.cpu().numpy() > 0.5).astype(np.uint8) * 255

    def evaluate(items, label):
        res = []
        for it in items:
            if it.get("_img") is not None:
                img = it["_img"]
            else:
                try:
                    img = load_image_256(resolve(it["file"]))
                except Exception:
                    continue
            true_m = np.asarray(rasterize(it["lasso"]),
                                dtype=np.uint8)
            pred_m = predict_mask(img)
            # Le POLYGONE SERVI (build 138) : ce que
            # le jeu reçoit réellement — le masque
            # passé par l'extraction du mode devine
            # (mask_to_polygon), rempli et comparé
            # au même tracé. Le bulletin mesurait
            # le masque brut ; l'écart entre les
            # deux nombres est le prix (ou le gain)
            # de l'extraction elle-même.
            # Build 139 : le servi évalué passe par
            # le MÊME raffinage que le devine — la
            # luminance pleine résolution de la
            # photo d'origine (ou, en mode
            # synthétique, l'image elle-même).
            gray = None
            if it.get("_img") is not None:
                gray = np.asarray(
                    it["_img"].convert("L"),
                    dtype=np.float64)
            elif it.get("file"):
                try:
                    gray = np.asarray(
                        Image.open(resolve(it["file"]))
                        .convert("L"),
                        dtype=np.float64)
                except Exception:
                    gray = None
            st = {}
            servi = mask_to_polygon(pred_m > 0,
                                    gray=gray, stats=st)
            if servi is not None:
                servi_m = np.asarray(
                    rasterize(servi), dtype=np.uint8)
                s_err = round(
                    chamfer_pct(servi_m, true_m), 2)
                s_iou = round(iou(servi_m, true_m), 3)
            else:
                s_err, s_iou = None, None
            res.append({
                "photo": it["sn"],
                "erreur_pct": round(chamfer_pct(pred_m, true_m), 2),
                "iou": round(iou(pred_m, true_m), 3),
                "servi_erreur_pct": s_err,
                "servi_iou": s_iou,
                "servi_depl_med_pct":
                    st.get("depl_med_pct"),
                "_true": true_m,
            })
            print(f"{label} photo {it['sn']} : erreur "
                  f"{res[-1]['erreur_pct']} % · IoU "
                  f"{res[-1]['iou']}", flush=True)
        return res

    dev_res = evaluate(dev_items, "dev")
    banc_res = evaluate(banc_items, "banc")
    # Examen strict (build 137) : le groupe de
    # reçus jamais entraîné — calculé et exclu
    # de l'entraînement depuis le début, mais
    # jamais ÉVALUÉ avant ce correctif : le
    # bulletin n'avait donc aucune section
    # « strict » et le test du document jamais
    # vu restait sans mesure.
    strict_res = evaluate(strict_items or [],
                          "strict")

    # Baseline boîte neutre sur le même dev.
    nm = np.asarray(neutral_mask(), dtype=np.uint8)
    box_err, box_iou = [], []
    for it, r in zip(dev_items, dev_res):
        box_err.append(chamfer_pct(nm, r["_true"]))
        box_iou.append(iou(nm, r["_true"]))
    for r in dev_res + banc_res + strict_res:
        r.pop("_true", None)

    def med(v):
        return round(float(np.median(v)), 2) if v else None

    def med_servi(res, cle):
        vals = [r[cle] for r in res
                if r.get(cle) is not None]
        return med(vals)

    bulletin = {
        "appareil": str(device),
        "epochs": epochs,
        "dev": {
            "n": len(dev_res),
            "erreur_mediane_pct": med(
                [r["erreur_pct"] for r in dev_res]),
            "erreur_moyenne_pct": round(
                float(np.mean(
                    [r["erreur_pct"] for r in dev_res])),
                2) if dev_res else None,
            "iou_mediane": med(
                [r["iou"] for r in dev_res]),
            "servi_erreur_mediane_pct": med_servi(
                dev_res, "servi_erreur_pct"),
            "servi_iou_mediane": med_servi(
                dev_res, "servi_iou"),
            "servi_depl_mediane_pct": med_servi(
                dev_res, "servi_depl_med_pct"),
            "boite_neutre": {
                "erreur_mediane_pct": med(box_err),
                "iou_mediane": med(
                    [round(v, 3) for v in box_iou]),
            },
            "par_photo": dev_res,
        },
        "banc": {
            "n": len(banc_res),
            "erreur_mediane_pct": med(
                [r["erreur_pct"] for r in banc_res]),
            "iou_mediane": med(
                [r["iou"] for r in banc_res]),
            "servi_erreur_mediane_pct": med_servi(
                banc_res, "servi_erreur_pct"),
            "servi_iou_mediane": med_servi(
                banc_res, "servi_iou"),
            "servi_depl_mediane_pct": med_servi(
                banc_res, "servi_depl_med_pct"),
            "par_photo": banc_res,
        },
    }
    if strict_res:
        bulletin["strict"] = {
            "n": len(strict_res),
            "erreur_mediane_pct": med(
                [r["erreur_pct"] for r in strict_res]),
            "iou_mediane": med(
                [r["iou"] for r in strict_res]),
            "servi_erreur_mediane_pct": med_servi(
                strict_res, "servi_erreur_pct"),
            "servi_iou_mediane": med_servi(
                strict_res, "servi_iou"),
            "servi_depl_mediane_pct": med_servi(
                strict_res, "servi_depl_med_pct"),
            "par_photo": strict_res,
        }
    # La recette du raffinage fait partie du
    # bulletin (build 139) : deux bulletins ne
    # sont comparables qu'à recette égale.
    bulletin["raffinage"] = {
        "fenetre_pct_diag": SNAP_FENETRE_PCT,
        "seuil_marche": SNAP_SEUIL_MARCHE,
    }
    return model, bulletin


# ---------------- Proposition (mode devine) ----

def _largest_component(mask):
    """Ne garde que la plus grande composante
    connexe (8-connexité) du masque. Les îlots
    parasites — quelques pixels faux positifs
    loin du reçu — devenaient des pics
    aberrants dans le polygone servi (retour
    terrain de Grégoire, build 136)."""
    from collections import deque
    H, W = mask.shape
    seen = np.zeros((H, W), dtype=bool)
    best = []
    ys, xs = np.nonzero(mask)
    for y0, x0 in zip(ys.tolist(), xs.tolist()):
        if seen[y0, x0]:
            continue
        comp = []
        dq = deque([(y0, x0)])
        seen[y0, x0] = True
        while dq:
            y, x = dq.popleft()
            comp.append((y, x))
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    ny, nx = y + dy, x + dx
                    if 0 <= ny < H and 0 <= nx < W \
                            and mask[ny, nx] \
                            and not seen[ny, nx]:
                        seen[ny, nx] = True
                        dq.append((ny, nx))
        if len(comp) > len(best):
            best = comp
    out = np.zeros((H, W), dtype=bool)
    for y, x in best:
        out[y, x] = True
    return out


# ---------------- Raffinage (build 139) ------

SNAP_FENETRE_PCT = 2.0  # fenêtre de recherche du
# bord réel, en % de la diagonale, de part et
# d'autre du point servi par le masque
SNAP_SEUIL_MARCHE = 24.0  # marche de luminance
# minimale (0-255) pour accepter un déplacement


def _bilinear(gray, xs, ys):
    """Échantillonnage bilinéaire vectorisé de
    l'image de luminance ; NaN hors image."""
    gh, gw = gray.shape
    x0 = np.floor(xs).astype(int)
    y0 = np.floor(ys).astype(int)
    fx = xs - x0
    fy = ys - y0
    ok = (x0 >= 0) & (y0 >= 0) & (x0 < gw - 1) \
        & (y0 < gh - 1)
    x0c = np.clip(x0, 0, gw - 2)
    y0c = np.clip(y0, 0, gh - 2)
    v = ((1 - fx) * (1 - fy) * gray[y0c, x0c]
         + fx * (1 - fy) * gray[y0c, x0c + 1]
         + (1 - fx) * fy * gray[y0c + 1, x0c]
         + fx * fy * gray[y0c + 1, x0c + 1])
    return np.where(ok, v, np.nan)


def _snap_radii(gray, cx, cy, radii, med, W, H):
    """Glisse chaque rayon vers le bord réel de
    la photo pleine résolution. Pour chaque
    rayon : profil de luminance le long du rayon
    dans la fenêtre ±SNAP_FENETRE_PCT autour du
    point du masque ; parmi les marches franches
    (≥ SNAP_SEUIL_MARCHE), on retient la plus
    PROCHE du point — le masque est déjà bon, le
    raffinage est local (une ligne imprimée à
    l'intérieur du reçu ne doit pas attirer le
    bord). Aucune marche franche -> abstention
    (déplacement 0). Les déplacements sont
    ensuite lissés par médiane circulaire
    (fenêtre 5) et les rayons reclampés dans la
    bande [0,6×, 1,3×] de la médiane locale du
    build 136 : jamais un pic réintroduit.
    Retourne (rayons raffinés, déplacements
    appliqués en pixels du masque)."""
    gh, gw = gray.shape
    S = (W + H) / 2.0
    win = SNAP_FENETRE_PCT / 100.0 * math.sqrt(2)
    s_vals = np.linspace(-win, win, 81)
    cnx, cny = cx / W, cy / H
    depl = [0.0] * len(radii)
    for k in range(len(radii)):
        th = 2 * math.pi * k / len(radii)
        ex = (cx + math.cos(th) * radii[k]) / W
        ey = (cy + math.sin(th) * radii[k]) / H
        vx, vy = ex - cnx, ey - cny
        dist = math.hypot(vx, vy)
        if dist < 1e-9:
            continue
        ux, uy = vx / dist, vy / dist
        px = cnx + (dist + s_vals) * ux
        py = cny + (dist + s_vals) * uy
        prof = _bilinear(gray, px * (gw - 1),
                         py * (gh - 1))
        if np.isnan(prof).any():
            continue
        grad = np.abs(prof[4:] - prof[:-4])
        # grad[i] est centré sur prof[i + 2].
        best = None
        for i in range(2, len(grad) - 2):
            if grad[i] < grad[i - 1] \
                    or grad[i] < grad[i + 1]:
                continue
            c = i + 2  # centre dans prof
            if c < 6 or c > len(prof) - 7:
                continue
            marche = abs(
                float(np.mean(prof[c + 2:c + 6]))
                - float(np.mean(prof[c - 6:c - 2])))
            if marche < SNAP_SEUIL_MARCHE:
                continue
            s = float(s_vals[c])
            if best is None or abs(s) < abs(best):
                best = s
        if best is not None:
            depl[k] = best * S
    # Médiane circulaire des déplacements.
    n = len(depl)
    lisse = []
    for k in range(n):
        w = sorted(depl[(k + j) % n]
                   for j in (-2, -1, 0, 1, 2))
        lisse.append(w[2])
    out = []
    for k in range(n):
        r = radii[k] + lisse[k]
        if med[k] > 0:
            r = min(max(r, 0.6 * med[k]),
                    1.3 * med[k])
        out.append(max(r, 2.0))
    return out, lisse


def mask_to_polygon(mask_bool, rays=144,
                    max_vertices=28, gray=None,
                    stats=None):
    """Masque -> polygone ordonné (build 136 :
    extraction renforcée). Un reçu est convexe :
    depuis le centroïde de sa plus grande
    composante connexe, on lance des rayons et
    on garde le point du masque le plus lointain
    sur chacun — un polygone ordonné par
    construction. Le profil des rayons est
    ensuite lissé (médiane circulaire) : un
    rayon qui dépasse ses voisins de plus de
    30 % est ramené à la médiane — le contour
    d'un reçu est régulier, un pic ne l'est
    pas. Puis simplification de Douglas-Peucker
    douce jusqu'à au plus `max_vertices`
    sommets (min 4).

    Build 139 : si `gray` (luminance pleine
    résolution) est fourni, chaque rayon est
    ensuite RAFFINÉ sur le bord réel par
    _snap_radii — fenêtre ±2 % de la diagonale,
    marche franche la plus proche, abstention
    sans marche, déplacements lissés et
    reclampés. Le bulletin nº 4 a montré que
    l'extraction régularise le masque sur le
    jamais-vu (strict servi 0,82 % contre
    1,82 %) mais laisse un plancher d'environ
    0,25 % sur le connu : c'est ce plancher que
    le raffinage attaque, sans toucher à la
    régularisation. `stats`, si fourni, reçoit
    « depl_med_pct » (déplacement médian
    appliqué, % de la diagonale) et « snap_frac »
    (part des rayons déplacés d'au moins 1 px)."""
    mask_bool = _largest_component(mask_bool)
    ys, xs = np.nonzero(mask_bool)
    if len(xs) < 50:
        return None
    cx, cy = xs.mean(), ys.mean()
    H, W = mask_bool.shape
    radii = [None] * rays
    for k in range(rays):
        th = 2 * math.pi * k / rays
        dx, dy = math.cos(th), math.sin(th)
        r = 0.0
        while True:
            r += 1.0
            x = int(round(cx + dx * r))
            y = int(round(cy + dy * r))
            if not (0 <= x < W and 0 <= y < H):
                break
            if mask_bool[y, x]:
                radii[k] = r
    present = [k for k in range(rays)
               if radii[k] is not None]
    if len(present) < rays // 2:
        return None
    # Rayons sans touche : recopier le plus
    # proche voisin présent (circulaire).
    for k in range(rays):
        if radii[k] is None:
            for d in range(1, rays):
                if radii[(k - d) % rays] is not None:
                    radii[k] = radii[(k - d) % rays]
                    break
                if radii[(k + d) % rays] is not None:
                    radii[k] = radii[(k + d) % rays]
                    break
    # Médiane circulaire (fenêtre 5) + rappel des
    # rayons aberrants à la médiane locale.
    med = []
    for k in range(rays):
        w = sorted(radii[(k + j) % rays]
                   for j in (-2, -1, 0, 1, 2))
        med.append(w[2])
    base = []
    for k in range(rays):
        r = radii[k]
        if med[k] > 0 and r > 1.30 * med[k]:
            r = med[k]
        base.append(r)
    if gray is not None:
        try:
            g = np.asarray(gray, dtype=np.float64)
            if g.ndim == 2 and g.size > 0:
                base, depl = _snap_radii(
                    g, cx, cy, base, med, W, H)
                if stats is not None:
                    diag = math.hypot(W, H)
                    stats["depl_med_pct"] = round(
                        float(np.median(
                            [abs(d) for d in depl]))
                        / diag * 100, 2)
                    stats["snap_frac"] = round(
                        sum(1 for d in depl
                            if abs(d) >= 1.0)
                        / len(depl), 3)
        except Exception:
            pass
    pts = []
    for k in range(rays):
        r = base[k]
        th = 2 * math.pi * k / rays
        pts.append(((cx + math.cos(th) * r) / W,
                    (cy + math.sin(th) * r) / H))
    # Dédoublonner les points consécutifs proches.
    dedup = [pts[0]]
    for p in pts[1:]:
        if abs(p[0] - dedup[-1][0]) > 1e-4 or \
                abs(p[1] - dedup[-1][1]) > 1e-4:
            dedup.append(p)
    if len(dedup) < 4:
        return None
    return _douglas_peucker(dedup, max_vertices)


def _douglas_peucker(pts, max_vertices):
    """Simplification d'un polygone FERMÉ :
    partir du diamètre (paire la plus éloignée),
    puis raffiner par seuils décroissants
    jusqu'à tenir dans le budget de sommets."""
    def seg_dist(p, a, b):
        ax, ay = a
        bx, by = b
        px, py = p
        dx, dy = bx - ax, by - ay
        L2 = dx * dx + dy * dy
        if L2 == 0:
            return math.hypot(px - ax, py - ay)
        t = max(0.0, min(1.0,
                         ((px - ax) * dx + (py - ay) * dy)
                         / L2))
        return math.hypot(px - (ax + t * dx),
                          py - (ay + t * dy))

    def dp(chain, eps):
        if len(chain) <= 2:
            return chain
        a, b = chain[0], chain[-1]
        dmax, idx = 0.0, -1
        for i in range(1, len(chain) - 1):
            d = seg_dist(chain[i], a, b)
            if d > dmax:
                dmax, idx = d, i
        if dmax > eps:
            left = dp(chain[:idx + 1], eps)
            right = dp(chain[idx:], eps)
            return left[:-1] + right
        return [a, b]

    n = len(pts)
    # Ancre : le point le plus éloigné du premier.
    j = max(range(n),
            key=lambda i: (pts[i][0] - pts[0][0]) ** 2
            + (pts[i][1] - pts[0][1]) ** 2)
    chain1 = pts[:j + 1]
    chain2 = pts[j:] + [pts[0]]
    eps = 0.0015
    for _ in range(24):
        out = dp(chain1, eps)[:-1] + dp(chain2, eps)[:-1]
        if len(out) <= max_vertices:
            return out if len(out) >= 4 else pts[:max(4, len(pts))]
        eps *= 1.6
    return out if len(out) >= 4 else None


def devine(image_path, sortie):
    """Charge contours-v0.pt, prédit le masque
    de l'image, imprime le polygone en JSON sur
    stdout (coordonnées normalisées)."""
    import torch
    modele = os.path.join(sortie, "contours-v0.pt")
    if not os.path.exists(modele):
        print(json.dumps({"erreur": "aucun modèle"}))
        return 3
    if torch.backends.mps.is_available():
        device = torch.device("mps")
    else:
        device = torch.device("cpu")
    model = build_model(torch).to(device)
    model.load_state_dict(torch.load(
        modele, map_location=device))
    model.eval()
    img = load_image_256(image_path)
    x = torch.from_numpy(
        np.asarray(img, dtype=np.float32) / 255.0
    ).permute(2, 0, 1).unsqueeze(0).to(device)
    with torch.no_grad():
        prob = torch.sigmoid(model(x))[0, 0].cpu().numpy()
    # Raffinage sur la photo pleine résolution
    # (build 139) : la même image que celle
    # réduite à 256 pour le réseau, mais lue dans
    # sa taille native pour la luminance.
    gray = None
    try:
        gray = np.asarray(
            Image.open(image_path).convert("L"),
            dtype=np.float64)
    except Exception:
        gray = None
    st = {}
    poly = mask_to_polygon(prob > 0.5, gray=gray,
                           stats=st)
    if poly is None:
        print(json.dumps({"erreur": "masque inexploitable"}))
        return 4
    out = {"lasso": [[round(px, 4), round(py, 4)]
                     for px, py in poly]}
    if "depl_med_pct" in st:
        out["depl_med_pct"] = st["depl_med_pct"]
        out["snap_frac"] = st.get("snap_frac")
    print(json.dumps(out))
    return 0


# ---------------- Main ----------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--racine", default=os.path.expanduser(
        "~/Library/Application Support/ScanRecus/Atelier"))
    ap.add_argument("--sortie", default=".")
    ap.add_argument("--epochs", type=int, default=60)
    ap.add_argument("--synthetique", action="store_true")
    ap.add_argument("--devine", default=None,
                    help="chemin d'une image : prédit "
                         "son contour et imprime le "
                         "polygone en JSON")
    args = ap.parse_args()

    if args.devine:
        return devine(args.devine, args.sortie)

    print("PHASE Chargement des élites…", flush=True)
    rng = np.random.default_rng(13)

    if args.synthetique:
        print("mode synthétique (test fumée)", flush=True)
        (X, Y), dev_items = synthetic_dataset(rng)
        for it in dev_items:
            it["_img"] = it["img"]
        banc_items = []
        n_train_elites, n_train_photos = 36, 36
        model, bulletin = train_and_eval(
            (X, Y), dev_items, banc_items,
            resolve=lambda name: name,
            epochs=args.epochs)
        bulletin["synthetique"] = True
        bulletin["n_train_elites"] = n_train_elites
        bulletin["n_train_photos"] = n_train_photos
    else:
        elites = load_elites(os.path.join(
            args.racine, "jeu.jsonl"))
        bench, strict = bench_sets(args.racine)
        resolve = build_resolver(args.racine)
        exam = bench | strict
        pool = [e for e in elites if e["sn"] not in exam]
        banc_items = [e for e in elites if e["sn"] in bench]
        strict_items = [e for e in elites
                        if e["sn"] in strict]
        print(f"élites : {len(elites)} au total · "
              f"{len(pool)} hors examen · "
              f"{len(banc_items)} au banc · "
              f"{len(strict_items)} au strict",
              flush=True)
        # Banc de fortune : photos du pool mises de
        # côté (1 sur 7, règle du banc), jamais
        # entraînées dans ce run.
        photos_pool = sorted({e["sn"] for e in pool})
        dev_photos = {p for i, p in enumerate(photos_pool)
                      if i % 7 == 3}
        train_elites = [e for e in pool
                        if e["sn"] not in dev_photos]
        dev_items = [e for e in pool
                     if e["sn"] in dev_photos]
        print(f"entraînement : {len(train_elites)} "
              f"élites / {len(photos_pool) - len(dev_photos)} "
              f"photos · dev (jamais entraînées) : "
              f"{len(dev_items)} élites / "
              f"{len(dev_photos)} photos "
              f"{sorted(dev_photos)}", flush=True)
        if len(train_elites) < 10 or not dev_items:
            print("Pas assez de données pour un test "
                  "honnête (il faut des élites des "
                  "deux côtés).", flush=True)
            return 2
        print("PHASE Préparation des exemples…",
              flush=True)
        X, Y = build_dataset(train_elites, resolve, rng)
        if X is None:
            print("Aucune image lisible.", flush=True)
            return 2
        for it in (dev_items + banc_items
                   + strict_items):
            it["_img"] = None
        print("PHASE Entraînement du traceur…",
              flush=True)
        model, bulletin = train_and_eval(
            (X, Y), dev_items, banc_items,
            resolve=resolve, epochs=args.epochs,
            strict_items=strict_items)
        bulletin["synthetique"] = False
        bulletin["n_train_elites"] = len(train_elites)
        bulletin["n_train_photos"] = (
            len(photos_pool) - len(dev_photos))
        bulletin["dev_photos"] = sorted(dev_photos)
        import torch
        torch.save(model.state_dict(), os.path.join(
            args.sortie, "contours-v0.pt"))

    import datetime
    bulletin["genere"] = datetime.datetime.now().strftime(
        "%Y-%m-%dT%H:%M:%S")
    out = os.path.join(args.sortie,
                       "bulletin-contours.json")
    with open(out, "w") as f:
        json.dump(bulletin, f, indent=1, sort_keys=True)
    dev = bulletin["dev"]
    print(f"DEV : erreur médiane "
          f"{dev['erreur_mediane_pct']} % · IoU "
          f"{dev['iou_mediane']} · boîte neutre "
          f"{dev['boite_neutre']['erreur_mediane_pct']} %",
          flush=True)
    print(f"bulletin écrit : {out}", flush=True)
    print("PROGRES 100", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
"""#
}
