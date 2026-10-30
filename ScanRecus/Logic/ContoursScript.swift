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

SIZE = 256  # œil du traceur : résolution
# d'entrée du réseau. Valeur initiale seulement :
# main() la règle d'après --taille (champ « Œil »
# de l'onglet Contours, défaut 256 — décision de
# Grégoire, build 156 ; le 512 du build 149 reste
# atteignable par le même champ).
CANEVAS_W, CANEVAS_H = 1600, 1207
# canevas de la fabrique : résolution native
# de la webcam (build 149)
NEUTRAL = (0.18, 0.82)  # boîte neutre du jeu


# ---------------- Banque / journal ----------------

# Groupes stricts RÉSERVÉS (build 153,
# décision de Grégoire, 2026-10-30) : les
# prochains reçus qu'il banque pour
# épaissir l'examen strict. La banque
# attribue les numéros de groupe au
# max + 1 (le dernier en date : 12) ; les
# groupes 13, 14 et 15 sont réservés
# d'avance — tant qu'ils n'existent pas,
# ils ne correspondent à rien ; dès qu'un
# reçu est coffré sous un de ces numéros,
# il est strict AVANT tout entraînement.
GROUPES_STRICTS_RESERVES = {13, 14, 15}


def bench_sets(racine):
    """(photos du banc par photo, photos de
    l'examen strict, groupes stricts) depuis
    le manifeste de la banque. Banc par
    photo : dans chaque groupe, les photos
    d'indice %7 == 3 (triées par numéro).
    Examen strict : le ou les groupes
    d'indice %7 == 3 dans la liste triée des
    groupes (le découpage historique), PLUS
    les groupes réservés (build 153) quand
    ils existent. Une photo strict n'est
    jamais aussi au banc : le strict
    gagne."""
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
    strict_groups |= (GROUPES_STRICTS_RESERVES
                      & set(groups))
    strict = {n for n, g in photos.items()
              if g in strict_groups}
    bench -= strict
    return bench, strict, strict_groups


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

def load_image_modele(path):
    img = Image.open(path).convert("RGB")
    return img.resize((SIZE, SIZE), Image.BILINEAR)


def rasterize(lasso, size=None):
    if size is None:
        size = SIZE
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    d.polygon([(x * size, y * size) for x, y in lasso],
              fill=255)
    return m


def _rasterize_rect(lasso, w, h):
    """Masque du lasso sur un canevas
    rectangulaire (fractions → pixels x·w,
    y·h) : le repère des photos natives,
    jamais écrasées en carré avant la
    découpe (build 148)."""
    m = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(m)
    d.polygon([(x * w, y * h) for x, y in lasso],
              fill=255)
    return m


def neutral_mask(size=None):
    if size is None:
        size = SIZE
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

def _homographie(src, dst):
    """Matrice H (3x3) telle que dst ≈ H·src
    pour 4 correspondances, et coefficients
    PIL de la transformation inverse (PIL
    veut la correspondance sortie → entrée)."""
    A = []
    for (x, y), (u, v) in zip(src, dst):
        A.append([x, y, 1, 0, 0, 0, -u * x, -u * y])
        A.append([0, 0, 0, x, y, 1, -v * x, -v * y])
    h = np.linalg.solve(
        np.array(A, dtype=np.float64),
        np.array([c for p in dst for c in p],
                 dtype=np.float64))
    H = np.array([[h[0], h[1], h[2]],
                  [h[3], h[4], h[5]],
                  [h[6], h[7], 1.0]])
    Hi = np.linalg.inv(H)
    Hi = Hi / Hi[2, 2]
    return H, tuple(Hi.flatten()[:8])


def _appliquer_H(H, pts):
    out = []
    for x, y in pts:
        w = H[2, 0] * x + H[2, 1] * y + H[2, 2]
        out.append((
            (H[0, 0] * x + H[0, 1] * y
             + H[0, 2]) / w,
            (H[1, 0] * x + H[1, 1] * y
             + H[1, 2]) / w))
    return out


def _fond_procedural(rng, W, H, blanc=False):
    """Toile procédurale au format du canevas :
    teinte douce, bruit léger, gradient à
    peine perceptible."""
    if blanc:
        base = float(rng.uniform(208, 242))
    else:
        base = float(rng.uniform(120, 215))
    arr = np.full((H, W, 3), base,
                  dtype=np.float64)
    teinte = rng.uniform(-8, 8, size=3)
    arr += teinte[None, None, :]
    arr += rng.normal(0, 5, (H, W, 1))
    pente = float(rng.uniform(-14, 14))
    arr += np.linspace(0, pente, W)[None, :, None]
    return Image.fromarray(
        np.clip(arr, 0, 255).astype(np.uint8))


def _fond_mine(donneur, rng, W, H, blanc=False):
    """Fond miné d'une autre scène : un
    rectangle au format du canevas qui évite
    le reçu du donneur (occupation < 1 %),
    ramené au canevas — l'étirement est
    permis pour les fonds (build 149). None
    si aucun crop propre (ou donneur
    illisible)."""
    try:
        img = Image.open(
            donneur["_chemin"]).convert("RGB")
    except Exception:
        return None
    W0, H0 = img.size
    msk = _rasterize_rect(donneur["lasso"], W0, H0)
    if blanc and np.asarray(
            img.convert("L"), dtype=np.float64
            ).mean() < 170:
        return None
    ratio = W / H
    for _ in range(24):
        ch = int(rng.uniform(0.45, 1.0) * H0)
        cw = int(ch * ratio)
        if cw > W0:
            cw = W0
            ch = int(cw / ratio)
        if ch > H0:
            ch = H0
            cw = int(ch * ratio)
        if cw < 50 or ch < 50:
            continue
        x0 = int(rng.integers(0, W0 - cw + 1))
        y0 = int(rng.integers(0, H0 - ch + 1))
        occ = np.asarray(
            msk.crop((x0, y0, x0 + cw, y0 + ch)),
            dtype=np.float64).mean() / 255.0
        if occ < 0.01:
            return img.crop(
                (x0, y0, x0 + cw, y0 + ch)).resize(
                    (W, H), Image.BILINEAR)
    return None


def _preparer_parents(train_elites, resolve):
    """Découpe chaque élite parente À PLEINE
    RÉSOLUTION (build 148, fabrique v2) : les
    pixels d'origine, sans réduction préalable
    de la scène ; alpha au bord net
    (adoucissement de 0,5 px à l'échelle
    native — sous le pixel une fois le reçu
    posé). L'éclairage d'origine est aplati
    par division floue, comme en v1 (parade
    partielle à la lumière « cuite »)."""
    from PIL import ImageFilter
    parents = []
    for idx, e in enumerate(train_elites):
        try:
            chemin = resolve(e["file"])
            img = Image.open(chemin).convert("RGB")
        except Exception:
            continue
        W0, H0 = img.size
        msk = _rasterize_rect(e["lasso"], W0, H0)
        boite = msk.getbbox()
        if boite is None:
            continue
        fg = img.crop(boite)
        al = msk.crop(boite).filter(
            ImageFilter.GaussianBlur(0.5))
        rayon = max(10.0, 0.06 * min(fg.size))
        lum = np.asarray(
            fg.convert("L"), dtype=np.float64)
        flou = np.asarray(
            fg.convert("L").filter(
                ImageFilter.GaussianBlur(rayon)),
            dtype=np.float64)
        corr = (flou.mean()
                / np.maximum(flou, 1.0))
        arr = np.asarray(fg, dtype=np.float64)
        plat = np.clip(
            arr * (0.5 + 0.5 * corr[:, :, None]),
            0, 255).astype(np.uint8)
        bw, bh = fg.size
        parents.append({
            "idx": idx, "sn": e["sn"],
            "fichier": e["file"],
            "lasso": e["lasso"],
            "_chemin": chemin,
            "fg": Image.fromarray(plat),
            "alpha": al, "boite": boite,
            "poly": [(x * W0, y * H0)
                     for x, y in e["lasso"]],
            "largeur_photo": W0,
            "frac_naturelle": bw / W0,
            "frac_boite": (bw / W0) * (bh / H0),
        })
    for p in parents:
        p["_pool"] = parents
    return parents


def _rogner(alpha, poly, rng):
    """Rogne le pourtour du reçu découpé :
    quelques arcs du contour rentrés vers le
    centre, et le tracé vérité SUIT la coupe
    (rognage SYSTÉMATIQUE et randomisé pour
    chaque variante — deux variantes d'une
    même élite n'ont jamais la même
    silhouette). Build 148 : coupes NETTES —
    le nouvel alpha est rasterisé franc
    depuis le polygone rogné (adoucissement
    de 0,5 px à l'échelle native seulement),
    la forme générale est préservée
    (garde-fou de surface à 60 %). Retourne
    (alpha, polygone) dans le repère local
    du parent, à résolution native."""
    from PIL import ImageFilter
    bw = alpha.size[0]
    pts = []
    n = len(poly)
    for i in range(n):
        x0, y0 = poly[i]
        x1, y1 = poly[(i + 1) % n]
        d = math.hypot(x1 - x0, y1 - y0)
        pas = max(1, int(d // 3))
        for k in range(pas):
            t = k / pas
            pts.append((x0 + (x1 - x0) * t,
                        y0 + (y1 - y0) * t))
    if len(pts) < 24:
        return alpha, poly
    cx = sum(x for x, _ in pts) / len(pts)
    cy = sum(y for _, y in pts) / len(pts)
    N = len(pts)
    prof = np.zeros(N)
    for _ in range(int(rng.integers(2, 6))):
        c = int(rng.integers(0, N))
        L = int(rng.integers(N // 20, N // 4))
        dep = float(rng.uniform(0.004, 0.016)) * bw
        for k in range(-L, L + 1):
            w = 0.5 * (1 + math.cos(
                math.pi * k / L))
            prof[(c + k) % N] = max(
                prof[(c + k) % N], dep * w)
    if prof.max() <= 0:
        return alpha, poly
    nou = []
    for i, (x, y) in enumerate(pts):
        d = prof[i]
        if d > 0:
            vx, vy = cx - x, cy - y
            nv = math.hypot(vx, vy) or 1.0
            x += vx / nv * d
            y += vy / nv * d
        nou.append((x, y))
    simp = _douglas_peucker(nou, 30,
                            eps0=0.003 * bw)
    if not simp or len(simp) < 4:
        return alpha, poly
    msk = Image.new("L", alpha.size, 0)
    ImageDraw.Draw(msk).polygon(simp, fill=255)
    aire0 = np.asarray(
        alpha, dtype=np.float64).sum()
    if (np.asarray(msk, dtype=np.float64).sum()
            < 0.6 * aire0):
        return alpha, poly
    msk = msk.filter(
        ImageFilter.GaussianBlur(0.5))
    return msk, simp


def _composer_variante(p, cat, rng, fond_img=None,
                       source_fond=None):
    """Compose UNE variante (fabrique v3,
    build 149) d'un parent préparé à pleine
    résolution, sur un canevas à la résolution
    native de la webcam (1600×1207) : fond
    (fourni, miné d'une autre scène ou
    procédural — ramené au canevas,
    l'étirement des fonds est permis),
    rognage NET du pourtour, DÉPÔT du reçu à
    sa taille naturelle (échelle 1,0) —
    rapetissé seulement si, une fois tourné,
    il sortirait du cadre —, monde refait
    par-dessus (ombre portée, gradient, piège
    à cheval), bruit léger pour sceller la
    couture et AUCUN flou. L'échantillonnage
    descendant vers l'entrée du modèle (512)
    se fait plus tard, au chargement.
    Retourne (image 1600×1207, polygone ou
    None, source du fond, angle en degrés ou
    None, échelle appliquée ≤ 1 ou None)."""
    from PIL import ImageFilter
    CW, CH = CANEVAS_W, CANEVAS_H
    E = CW / 512.0  # échelle des effets
    bw, bh = p["fg"].size
    bx0, by0 = p["boite"][0], p["boite"][1]
    poly_arr = [(x - bx0, y - by0)
                for x, y in p["poly"]]
    # --- fond ---
    if fond_img is not None:
        fond = fond_img
        src = source_fond or "fourni"
    else:
        fond = None
        src = "procédural"
        if cat != "blanc" or rng.random() < 0.5:
            cands = [q for q in p["_pool"]
                     if q["sn"] != p["sn"]]
            if cands:
                q = cands[int(rng.integers(
                    0, len(cands)))]
                fond = _fond_mine(
                    q, rng, CW, CH,
                    blanc=(cat == "blanc"))
                if fond is not None:
                    src = f"miné photo {q['sn']}"
        if fond is None:
            fond = _fond_procedural(
                rng, CW, CH, blanc=(cat == "blanc"))
            src = "procédural"
    if fond.size != (CW, CH):
        fond = fond.resize((CW, CH), Image.BILINEAR)
    arr = np.asarray(fond, dtype=np.float64)
    if cat == "ombre":
        arr = np.clip(arr * float(
            rng.uniform(1.06, 1.18)), 0, 255)
    if cat == "blanc" and fond_img is not None:
        # un fond web fourni n'est pas
        # nécessairement clair : on l'éclaircit
        # pour fabriquer le piège blanc sur blanc
        arr = np.clip(arr * 1.2 + 15, 0, 255)
    poly_final = None
    ang_deg = None
    zoom = None
    if cat != "négatif":
        # --- rognage : systématique, randomisé, net
        alpha_pose, poly_arr = _rogner(
            p["alpha"], poly_arr, rng)
        # --- dépôt du reçu, à taille naturelle ---
        fg = p["fg"]
        if cat == "ombre":
            fg = Image.fromarray(np.clip(
                np.asarray(fg, dtype=np.float64)
                * float(rng.uniform(0.7, 0.88)),
                0, 255).astype(np.uint8))
        ang = math.radians(float(
            rng.uniform(-180, 180)))
        ang_deg = round(math.degrees(ang), 1)
        cx = float(rng.uniform(0.36, 0.64)) * CW
        cy = float(rng.uniform(0.36, 0.64)) * CH
        src_q = [(0, 0), (bw, 0), (bw, bh), (0, bh)]
        dst_q = []
        for dx, dy in [(-bw / 2, -bh / 2),
                       (bw / 2, -bh / 2),
                       (bw / 2, bh / 2),
                       (-bw / 2, bh / 2)]:
            rx = (dx * math.cos(ang)
                  - dy * math.sin(ang))
            ry = (dx * math.sin(ang)
                  + dy * math.cos(ang))
            dst_q.append((
                cx + rx + float(rng.uniform(
                    -0.05, 0.05)) * bw,
                cy + ry + float(rng.uniform(
                    -0.05, 0.05)) * bw))
        # rapetisser SEULEMENT si le reçu tourné
        # sortirait du cadre (marge de 8 px)
        m = 8.0
        ech = 1.0
        for qx, qy in dst_q:
            if qx > cx:
                ech = min(ech, (CW - m - cx)
                          / (qx - cx))
            elif qx < cx:
                ech = min(ech, (m - cx) / (qx - cx))
            if qy > cy:
                ech = min(ech, (CH - m - cy)
                          / (qy - cy))
            elif qy < cy:
                ech = min(ech, (m - cy) / (qy - cy))
        ech = max(ech, 0.05)
        if ech < 1.0:
            dst_q = [(cx + (qx - cx) * ech,
                      cy + (qy - cy) * ech)
                     for qx, qy in dst_q]
        zoom = round(ech, 3)
        H, coeffs = _homographie(src_q, dst_q)
        fg_w = fg.transform(
            (CW, CH), Image.PERSPECTIVE, coeffs,
            Image.BILINEAR)
        al_w = alpha_pose.transform(
            (CW, CH), Image.PERSPECTIVE, coeffs,
            Image.BILINEAR)
        poly_final = _appliquer_H(H, poly_arr)
        # --- monde refait : ombre portée ---
        dx = float(rng.uniform(-16, 16)) * E
        dy = float(rng.uniform(4, 18)) * E
        ombre = al_w.transform(
            (CW, CH), Image.AFFINE,
            (1, 0, -dx, 0, 1, -dy),
            Image.BILINEAR).filter(
                ImageFilter.GaussianBlur(5 * E))
        a_o = np.asarray(
            ombre, dtype=np.float64) / 255.0
        arr = arr * (1 - 0.38 * a_o[:, :, None])
        # --- collage du reçu ---
        a = np.asarray(
            al_w, dtype=np.float64) / 255.0
        arr = (arr * (1 - a[:, :, None])
               + np.asarray(fg_w, dtype=np.float64)
               * a[:, :, None])
    # --- monde refait : gradient de lumière ---
    th_g = float(rng.uniform(0, 6.2832))
    amp = float(rng.uniform(-0.22, 0.22))
    gx = np.linspace(0, 1, CW)[None, :]
    gy = np.linspace(0, 1, CH)[:, None]
    champ = 1 + amp * (
        (gx * math.cos(th_g)
         + gy * math.sin(th_g)) - 0.5)
    arr = arr * champ[:, :, None]
    # --- piège : surexposition à cheval ---
    if cat in ("surexposition", "blanc"):
        if poly_final:
            vx, vy = poly_final[int(rng.integers(
                0, len(poly_final)))]
        else:
            vx, vy = CW / 2, CH / 2
        vx += float(rng.uniform(-24, 24)) * E
        vy += float(rng.uniform(-24, 24)) * E
        rayon = float(rng.uniform(60, 200)) * E
        force = (0.55 if cat == "surexposition"
                 else 0.35) + float(
                     rng.uniform(0, 0.35))
        xx = np.linspace(0, CW, CW)[None, :]
        yy = np.linspace(0, CH, CH)[:, None]
        d2 = ((xx - vx) ** 2 + (yy - vy) ** 2)
        infl = np.exp(
            -d2 / (rayon ** 2)) * force
        arr = (arr * (1 - infl[:, :, None])
               + 255.0 * infl[:, :, None])
    # --- finition : bruit léger, aucun flou ---
    arr += rng.normal(
        0, float(rng.uniform(0.5, 1.2)), (CH, CW, 1))
    img = Image.fromarray(np.clip(
        arr, 0, 255).astype(np.uint8))
    return img, poly_final, src, ang_deg, zoom


def fabriquer_banque(racine, fonds_par_elite=6,
                     angles=10, limite=0):
    """FABRIQUE v4 (build 150) : banque
    synthétique PERMANENTE dans
    racine/Synthetique, fabriquée aux règles
    de Grégoire — canevas à la résolution
    native de la webcam (1600×1207), fonds
    ramenés au canevas (étirement permis
    pour les fonds), découpages déposés à
    leur taille naturelle, rapetissés
    seulement si la rotation les fait
    sortir du cadre, rognures nettes, bords
    sans flou. Images stockées en HEIC
    qualité 90 — le format de ses scans.
    Chaque élite
    d'entraînement — PARENTS SEULEMENT
    (jamais dev, banc ni strict) — est posée
    sur des fonds variés (web déposés dans
    racine/Fonds, minés des scènes
    d'entraînement, procéduraux). La vérité
    de chaque image est le tracé de son
    élite, transformé avec elle, consigné au
    manifeste banque-synth.jsonl (avec le
    zoom appliqué, ≤ 1 par construction).
    Idempotente : un fichier déjà au
    manifeste n'est pas refabriqué — la
    banque GRANDIT. `limite` > 0 : aperçu —
    s'arrêter après ce nombre d'images
    NOUVELLES ; les parents sont alors
    traités des extrêmes vers le centre
    (plus grand et plus petit reçu d'abord),
    pour que l'aperçu montre le contraste."""
    sp = prepare_splits(racine)
    parents = _preparer_parents(
        sp["train_elites"], sp["resolve"])
    if not parents:
        print("Aucune élite d'entraînement : "
              "fabrique impossible.", flush=True)
        return 2
    # ordre des extrêmes vers le centre
    parents.sort(key=lambda p: -p["frac_boite"])
    ordre = []
    i, j = 0, len(parents) - 1
    while i <= j:
        ordre.append(parents[i])
        if j != i:
            ordre.append(parents[j])
        i += 1
        j -= 1
    parents = ordre
    rng = np.random.default_rng(150)
    dossier = os.path.join(racine, "Synthetique")
    os.makedirs(dossier, exist_ok=True)
    man_path = os.path.join(
        dossier, "banque-synth.jsonl")
    faits = set()
    if os.path.exists(man_path):
        for line in open(man_path):
            line = line.strip()
            if line:
                try:
                    faits.add(json.loads(line)
                              ["fichier"])
                except Exception:
                    pass
    fonds_web = []
    dir_fonds = os.path.join(racine, "Fonds")
    if os.path.isdir(dir_fonds):
        for nom in sorted(os.listdir(dir_fonds)):
            if nom.lower().endswith(
                    (".jpg", ".jpeg", ".png")):
                fonds_web.append(os.path.join(
                    dir_fonds, nom))
    print(f"fabrique v4 : {len(parents)} parents · "
          f"{len(fonds_web)} fonds web · "
          f"{fonds_par_elite} fonds × {angles} "
          f"angles par élite"
          + (f" · limite {limite}" if limite
             else ""), flush=True)
    pieges = ["surexposition", "blanc", "ombre"]
    total = (len(parents) * fonds_par_elite
             * angles)
    fait = 0
    nouveaux = 0
    stop = False
    man = open(man_path, "a")
    fonds_cache = {}

    def fond_pour(p, f):
        """Fond web du couple (parent, f), tiré
        une seule fois et mis en cache : les
        boucles tournent par angle d'abord,
        pour qu'une petite limite échantillonne
        tous les parents (extrêmes d'abord)."""
        cle = (p["idx"], f)
        if cle in fonds_cache:
            return fonds_cache[cle]
        fond_img = None
        source = None
        if fonds_web and (p["idx"] + f) % 5 in (0, 1, 3):
            chemin_fond = fonds_web[int(
                rng.integers(0, len(fonds_web)))]
            try:
                bf = Image.open(
                    chemin_fond).convert("RGB")
                ratio = CANEVAS_W / CANEVAS_H
                ch = int(rng.uniform(
                    0.5, 1.0) * bf.size[1])
                cw = int(ch * ratio)
                if cw > bf.size[0]:
                    cw = bf.size[0]
                    ch = int(cw / ratio)
                if ch > bf.size[1]:
                    ch = bf.size[1]
                    cw = int(ch * ratio)
                x0 = int(rng.integers(
                    0, bf.size[0] - cw + 1))
                y0 = int(rng.integers(
                    0, bf.size[1] - ch + 1))
                fond_img = bf.crop(
                    (x0, y0, x0 + cw, y0 + ch)
                    ).resize((CANEVAS_W, CANEVAS_H),
                             Image.BILINEAR)
                source = ("web " + os.path.basename(
                    chemin_fond))
            except Exception:
                fond_img = None
                source = None
        fonds_cache[cle] = (fond_img, source)
        return fond_img, source

    for a in range(angles):
        if stop:
            break
        for f in range(fonds_par_elite):
            if stop:
                break
            for p in parents:
                if stop:
                    break
                nom = (f"synth-{p['idx']:03d}"
                       f"-f{f}-a{a}.heic")
                fait += 1
                if nom in faits:
                    continue
                if a == 3:
                    cat = pieges[(p["idx"] + f) % 3]
                elif a == 8:
                    cat = pieges[(p["idx"] + f + 1) % 3]
                elif a == 5 and p["idx"] % 8 == 7:
                    cat = "négatif"
                else:
                    cat = "libre"
                fond_img, source = fond_pour(p, f)
                img, poly, src, ang, zoom = \
                    _composer_variante(
                        p, cat, rng,
                        fond_img=fond_img,
                        source_fond=source)
                img.save(os.path.join(dossier, nom),
                         quality=90)
                man.write(json.dumps({
                    "fichier": nom,
                    "parent_sn": p["sn"],
                    "parent_fichier": p["fichier"],
                    "categorie": cat,
                    "fond": src,
                    "angle": ang,
                    "moteur": "v4",
                    "zoom": zoom,
                    "poly": ([[round(x / CANEVAS_W, 5),
                               round(y / CANEVAS_H, 5)]
                              for x, y in poly]
                             if poly else None),
                }) + "\n")
                man.flush()
                nouveaux += 1
                if limite and nouveaux >= limite:
                    print(f"limite d'aperçu atteinte : "
                          f"{nouveaux} image(s) "
                          f"nouvelle(s)", flush=True)
                    stop = True
                if fait % 100 == 0:
                    print(f"PROGRES "
                          f"{int(100 * fait / total)}",
                          flush=True)
                    print(f"fabrique : {fait}/"
                          f"{total}", flush=True)
    man.close()
    info = {"n": len(faits) + nouveaux,
            "n_parents": len(parents),
            "fonds_web": len(fonds_web),
            "par_elite": fonds_par_elite * angles,
            "moteur": "v4",
            "taille": [CANEVAS_W, CANEVAS_H],
            "format": "heic", "qualite": 90}
    with open(os.path.join(
            dossier, "banque-synth-info.json"),
            "w") as fh:
        json.dump(info, fh, indent=1,
                  sort_keys=True)
    print(f"banque synthétique : {info['n']} "
          f"images ({nouveaux} nouvelles) dans "
          f"{dossier}", flush=True)
    return 0


def charger_banque_synth(racine):
    """Charge la banque synthétique permanente
    (racine/Synthetique) : (X, Y) aux formats
    de build_dataset, ou None si elle n'existe
    pas. Les masques sont rasterisés depuis
    les polygones du manifeste — les tracés
    des élites parentes, transformés."""
    dossier = os.path.join(racine, "Synthetique")
    man_path = os.path.join(
        dossier, "banque-synth.jsonl")
    if not os.path.exists(man_path):
        return None
    xs, ys = [], []
    for line in open(man_path):
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
            img = Image.open(os.path.join(
                dossier, e["fichier"])).convert(
                    "RGB")
            if img.size != (SIZE, SIZE):
                img = img.resize(
                    (SIZE, SIZE), Image.BILINEAR)
        except Exception:
            continue
        xs.append(np.asarray(img, dtype=np.uint8))
        if e.get("poly"):
            ys.append(np.asarray(
                rasterize(e["poly"]),
                dtype=np.uint8))
        else:
            ys.append(np.zeros(
                (SIZE, SIZE), dtype=np.uint8))
    if not xs:
        return None
    return np.stack(xs), np.stack(ys)


def build_dataset(elites, resolve, rng, rotations=11):
    """(X uint8 [N,SIZE,SIZE,3], Y uint8 [N,SIZE,SIZE])
    : chaque élite en native + `rotations`
    variantes tournées (image et masque ensemble,
    jamais de miroir)."""
    xs, ys = [], []
    for i, e in enumerate(elites):
        path = resolve(e["file"])
        try:
            img = load_image_modele(path)
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

def pick_device(torch):
    """Le meilleur appareil de calcul dispo-
    nible : MPS (Apple Silicon), sinon CUDA,
    sinon le CPU."""
    if torch.backends.mps.is_available():
        return torch.device("mps")
    if torch.cuda.is_available():
        return torch.device("cuda")
    return torch.device("cpu")


def evaluate_model(model, device, dev_items,
                   banc_items, resolve,
                   strict_items=None):
    """Évalue un traceur sur les photos d'examen
    (banc de fortune / vrai banc / strict) et
    assemble le bulletin, SANS entraîner.
    Build 140 : cette évaluation vivait soudée
    à l'entraînement dans train_and_eval — on
    ne pouvait mesurer un changement
    d'extraction (build 139) qu'en payant un
    entraînement complet. Elle est maintenant
    autonome : l'entraînement l'appelle, et le
    mode --evalue l'appelle seule sur le modèle
    existant. Le bulletin produit est le même
    dans les deux cas."""
    import torch

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
                    img = load_image_modele(resolve(it["file"]))
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
            servi_txt = (
                f" · servi {res[-1]['servi_erreur_pct']} %"
                if res[-1]['servi_erreur_pct'] is not None
                else "")
            print(f"{label} photo {it['sn']} : erreur "
                  f"{res[-1]['erreur_pct']} % · IoU "
                  f"{res[-1]['iou']}{servi_txt}",
                  flush=True)
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
        "fenetre_pct_diag": PARAMS_COURANTS["fenetre_pct"],
        "seuil_marche": PARAMS_COURANTS["seuil_marche"],
        "params": dict(PARAMS_COURANTS),
        "params_source": PARAMS_SOURCE,
    }
    return bulletin


def _maj_selection(meilleur_score, sans_progress,
                   score):
    """Comptabilité de l'arrêt anticipé
    (build 151) : un score (déviation du dev
    au servi, plus bas = mieux) qui bat le
    meilleur remet le compteur à zéro ; sinon
    il monte d'un cran. Fonction pure — la
    fumée la teste telle quelle."""
    if score is not None and (
            meilleur_score is None
            or score < meilleur_score):
        return score, 0, True
    return (meilleur_score,
            sans_progress + 1, False)


def train_and_eval(train_xy, dev_items, banc_items,
                   resolve, epochs, seed=13,
                   strict_items=None,
                   dossier_archives=None,
                   patience=8):
    import torch
    import torch.nn.functional as Fn

    device = pick_device(torch)
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
    batch = 8
    pertes = []
    # Sélection par époque (build 151, barème
    # renversé au build 152 — décisions de
    # Grégoire) : après chaque époque, l'IA
    # de l'époque est ARCHIVÉE sous un nom
    # unique (une époque = une IA unique,
    # aucune n'est jamais effacée), puis une
    # COPIE jetable de cette IA passe
    # l'examen dev+strict ; c'est le STRICT
    # qui choisit (reçus entiers jamais
    # vus, comme en vie réelle — le dev ne
    # mesure que des photos nouvelles de
    # reçus connus), au score MOYENNE +
    # PIRE CAS des servis (build 154 : le
    # barème de la lecture humaine — la
    # médiane seule couronnait la majorité
    # facile en ignorant la catastrophe).
    # Huit époques de suite sans progrès
    # arrêtent la course ; la
    # meilleure IA archivée devient le
    # modèle servi, les autres restent dans
    # les archives, choisissables dans
    # l'app (sélecteur du premier onglet).
    import contextlib
    import gc
    import io
    hist_evals = []
    metrique_sel = 'dev'
    meilleur_score = None
    meilleure_ep = None
    meilleur_chemin = None
    sans_progress = 0
    arrete = False
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
        pertes.append(round(tot_loss / n, 4))
        if dossier_archives:
            os.makedirs(dossier_archives,
                        exist_ok=True)
            chemin_ep = os.path.join(
                dossier_archives,
                f"epoque-{ep + 1:02d}.pt")
            torch.save(model.state_dict(),
                       chemin_ep)
            # L'examen est passé par une COPIE
            # de l'IA archivée, jamais par le
            # modèle en entraînement ; la
            # copie est jetée après l'examen,
            # l'archive reste.
            copie = build_model(torch).to(device)
            copie.load_state_dict(torch.load(
                chemin_ep, map_location=device))
            copie.eval()
            with contextlib.redirect_stdout(
                    io.StringIO()):
                b_ep = evaluate_model(
                    copie, device, dev_items, [],
                    resolve,
                    strict_items=strict_items)
            del copie
            gc.collect()
            dev_b = b_ep["dev"]
            strict_b = b_ep.get("strict")
            if strict_b:
                metrique_sel = "strict"
            base_b = strict_b or dev_b
            servis = [r["servi_erreur_pct"]
                      for r in
                      base_b["par_photo"]]
            moy = (round(sum(servis)
                         / len(servis), 4)
                   if servis else None)
            pire = (max(servis)
                    if servis else None)
            score = (round(moy + pire, 4)
                     if moy is not None
                     else base_b[
                         "servi_erreur_mediane_pct"])
            hist_evals.append({
                "epoque": ep + 1,
                "dev_servi_pct": dev_b[
                    "servi_erreur_mediane_pct"],
                "dev_masque_pct": dev_b[
                    "erreur_mediane_pct"],
                "strict_servi_pct":
                    strict_b[
                        "servi_erreur_mediane_pct"]
                    if strict_b else None,
                "strict_masque_pct":
                    strict_b[
                        "erreur_mediane_pct"]
                    if strict_b else None,
                "strict_servi_moyenne_pct":
                    moy if strict_b else None,
                "strict_servi_pire_pct":
                    pire if strict_b else None,
                "score_selection_pct": score,
                "archive": os.path.basename(
                    chemin_ep)})
            # Les scores en temps réel, photo par
            # photo (demande de Grégoire) : c'est
            # ce défilement qu'il regardera
            # pendant que les tests se font.
            for r in b_ep["dev"]["par_photo"]:
                print(f"   dev photo {r['photo']} : "
                      f"servi "
                      f"{r['servi_erreur_pct']} % · "
                      f"masque {r['erreur_pct']} %",
                      flush=True)
            if strict_b:
                for r in strict_b["par_photo"]:
                    print(f"   strict photo "
                          f"{r['photo']} : servi "
                          f"{r['servi_erreur_pct']}"
                          f" % · masque "
                          f"{r['erreur_pct']} %",
                          flush=True)
            print(f"   examen passé par la copie "
                  f"de {hist_evals[-1]['archive']}"
                  f" (archive conservée)",
                  flush=True)
            (meilleur_score, sans_progress,
             ameliore) = _maj_selection(
                meilleur_score, sans_progress,
                score)
            if ameliore:
                meilleure_ep = ep + 1
                meilleur_chemin = chemin_ep
            print(f"époque {ep + 1} — "
                  f"{metrique_sel} : moyenne "
                  f"{moy} % · pire {pire} % · "
                  f"score {score} % · "
                  f"meilleur : "
                  f"époque {meilleure_ep}",
                  flush=True)
            if sans_progress >= patience:
                print(f"arrêt anticipé : "
                      f"{patience} époques sans "
                      f"progrès sur le "
                      f"{metrique_sel}",
                      flush=True)
                arrete = True
                break

    if meilleur_chemin is not None:
        model.load_state_dict(torch.load(
            meilleur_chemin, map_location=device))
        model.to(device)
        print(f"sélection : meilleure époque "
              f"{meilleure_ep} ({metrique_sel} "
              f"servi {meilleur_score} %) — "
              f"{len(hist_evals)} IA archivées "
              f"dans {dossier_archives}, aucune "
              f"effacée",
              flush=True)
    bulletin = evaluate_model(
        model, device, dev_items, banc_items,
        resolve, strict_items=strict_items)
    bulletin["epochs"] = len(pertes)
    bulletin["epochs_demandees"] = epochs
    bulletin["pertes"] = pertes
    if hist_evals:
        bulletin["selection"] = {
            "metrique":
                f"{metrique_sel} servi "
                "(moyenne + pire cas)",
            "meilleure_epoque": meilleure_ep,
            "meilleur_score_pct": meilleur_score,
            "patience": patience,
            "arrete_tot": arrete,
            "evaluations": hist_evals,
            "archives": {
                "dossier": dossier_archives,
                "fichiers": [e["archive"]
                             for e in hist_evals]}}
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

# Paramètres d'extraction (build 143) : le
# TENANT est le jeu de constantes des builds
# 136/139. Un champion de tournoi peut le
# remplacer via extraction-champion.json dans
# le dossier de sortie (voir tournoi_seul) —
# c'est le seul endroit où ces nombres bougent,
# et le bulletin consigne lesquels ont servi.
PARAMS_DEFAUT = {
    "fenetre_pct": 2.0,
    "seuil_marche": 24.0,
    "bande_bas": 0.6,
    "bande_haut": 1.3,
    "clip": 1.30,
    "dp_eps": 0.0015,
}
PARAMS_COURANTS = dict(PARAMS_DEFAUT)
PARAMS_SOURCE = "défaut"


def charger_params(sortie):
    """Charge le champion du tournoi s'il
    existe dans `sortie`, sinon les défauts.
    Retourne (params, source)."""
    global PARAMS_COURANTS, PARAMS_SOURCE
    p = dict(PARAMS_DEFAUT)
    source = "défaut"
    try:
        f = os.path.join(
            sortie, "extraction-champion.json")
        if os.path.exists(f):
            data = json.load(open(f))
            for k in p:
                if k in data.get("params", {}):
                    p[k] = float(data["params"][k])
            source = "tournoi"
    except Exception:
        pass
    PARAMS_COURANTS = p
    PARAMS_SOURCE = source
    return p, source




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


def _snap_radii(gray, cx, cy, radii, med, W, H,
                params):
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
    win = params["fenetre_pct"] / 100.0 * math.sqrt(2)
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
            if marche < params["seuil_marche"]:
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
            r = min(max(r, params["bande_bas"] * med[k]),
                    params["bande_haut"] * med[k])
        out.append(max(r, 2.0))
    return out, lisse


def mask_to_polygon(mask_bool, rays=144,
                    max_vertices=28, gray=None,
                    stats=None, params=None):
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
    if params is None:
        params = PARAMS_COURANTS
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
        if med[k] > 0 and r > params["clip"] * med[k]:
            r = med[k]
        base.append(r)
    if gray is not None:
        try:
            g = np.asarray(gray, dtype=np.float64)
            if g.ndim == 2 and g.size > 0:
                base, depl = _snap_radii(
                    g, cx, cy, base, med, W, H,
                    params)
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
    return _douglas_peucker(
        dedup, max_vertices, eps0=params["dp_eps"])


def _douglas_peucker(pts, max_vertices,
                     eps0=0.0015):
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
    eps = eps0
    for _ in range(24):
        out = dp(chain1, eps)[:-1] + dp(chain2, eps)[:-1]
        if len(out) <= max_vertices:
            return out if len(out) >= 4 else pts[:max(4, len(pts))]
        eps *= 1.6
    return out if len(out) >= 4 else None


def devine(image_path, sortie,
           modele_choisi=None):
    """Charge le modèle (contours-v0.pt par
    défaut, ou celui du sélecteur d'IA via
    --modele), prédit le masque de l'image,
    imprime le polygone en JSON sur stdout
    (coordonnées normalisées)."""
    import torch
    modele = modele_choisi or os.path.join(
        sortie, "contours-v0.pt")
    if not os.path.exists(modele):
        print(json.dumps({"erreur": "aucun modèle"}))
        return 3
    charger_params(sortie)
    if torch.backends.mps.is_available():
        device = torch.device("mps")
    else:
        device = torch.device("cpu")
    model = build_model(torch).to(device)
    model.load_state_dict(torch.load(
        modele, map_location=device))
    model.eval()
    img = load_image_modele(image_path)
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


# ---------------- Découpage / évalue seule ---

def prepare_splits(racine):
    """Le découpage d'examen du journal, calculé
    de la même façon pour l'entraînement et pour
    l'évaluation seule (build 140) : examen =
    banc par photo + groupe strict (exclus de
    l'entraînement) ; dans le pool restant, banc
    de fortune = photos mises de côté 1 sur 7,
    jamais entraînées dans le run."""
    elites = load_elites(os.path.join(
        racine, "jeu.jsonl"))
    bench, strict, strict_groupes = \
        bench_sets(racine)
    resolve = build_resolver(racine)
    exam = bench | strict
    pool = [e for e in elites if e["sn"] not in exam]
    banc_items = [e for e in elites if e["sn"] in bench]
    strict_items = [e for e in elites
                    if e["sn"] in strict]
    photos_pool = sorted({e["sn"] for e in pool})
    dev_photos = {p for i, p in enumerate(photos_pool)
                  if i % 7 == 3}
    train_elites = [e for e in pool
                    if e["sn"] not in dev_photos]
    dev_items = [e for e in pool
                 if e["sn"] in dev_photos]
    return {
        "elites": elites, "resolve": resolve,
        "pool": pool, "banc_items": banc_items,
        "strict_items": strict_items,
        "strict_groupes": sorted(strict_groupes),
        "photos_pool": photos_pool,
        "dev_photos": dev_photos,
        "train_elites": train_elites,
        "dev_items": dev_items,
    }


def evaluer_seul(args):
    """Mode évaluation seule (build 140) :
    charge le modèle existant (contours-v0.pt
    dans --sortie) et régénère le bulletin SANS
    entraîner — le modèle n'est ni retouché ni
    réécrit. C'est le geste qui rend les
    réglages d'extraction mesurables en une
    minute au lieu de vingt. Le bulletin
    déclare son mode (« evaluation ») et la
    date du fichier modèle mesuré : un bulletin
    d'évaluation ne doit jamais pouvoir passer
    pour un bulletin d'entraînement."""
    import torch
    modele = os.path.join(args.sortie,
                          "contours-v0.pt")
    if not os.path.exists(modele):
        print("Évaluation seule impossible : "
              "aucun modèle (contours-v0.pt) dans "
              "le dossier de sortie — entraînez "
              "d'abord le traceur.", flush=True)
        return 3
    charger_params(args.sortie)
    sp = prepare_splits(args.racine)
    print(f"élites : {len(sp['elites'])} au total · "
          f"{len(sp['dev_items'])} au banc de "
          f"fortune · {len(sp['banc_items'])} au "
          f"banc · {len(sp['strict_items'])} au "
          f"strict", flush=True)
    if not (sp["dev_items"] or sp["banc_items"]
            or sp["strict_items"]):
        print("Aucune photo d'examen à évaluer.",
              flush=True)
        return 2
    device = pick_device(torch)
    print(f"appareil : {device}", flush=True)
    model = build_model(torch).to(device)
    model.load_state_dict(torch.load(
        modele, map_location=device))
    for it in (sp["dev_items"] + sp["banc_items"]
               + sp["strict_items"]):
        it["_img"] = None
    print("PHASE Évaluation du modèle existant…",
          flush=True)
    print("PROGRES 30", flush=True)
    bulletin = evaluate_model(
        model, device, sp["dev_items"],
        sp["banc_items"], sp["resolve"],
        strict_items=sp["strict_items"])
    bulletin["mode"] = "evaluation"
    bulletin["synthetique"] = False
    bulletin["n_train_elites"] = len(
        sp["train_elites"])
    bulletin["n_train_photos"] = (
        len(sp["photos_pool"])
        - len(sp["dev_photos"]))
    bulletin["dev_photos"] = sorted(sp["dev_photos"])
    bulletin["strict_groupes"] = \
        sp["strict_groupes"]
    import datetime
    bulletin["modele_mtime"] = (
        datetime.datetime.fromtimestamp(
            os.path.getmtime(modele))
        .strftime("%Y-%m-%dT%H:%M:%S"))
    bulletin["genere"] = datetime.datetime.now(
    ).strftime("%Y-%m-%dT%H:%M:%S")
    out = os.path.join(args.sortie,
                       "bulletin-contours.json")
    with open(out, "w") as f:
        json.dump(bulletin, f, indent=1,
                  sort_keys=True)
    dev = bulletin["dev"]
    print(f"DEV : erreur médiane "
          f"{dev['erreur_mediane_pct']} % · IoU "
          f"{dev['iou_mediane']} · boîte neutre "
          f"{dev['boite_neutre']['erreur_mediane_pct']} %",
          flush=True)
    print(f"bulletin écrit : {out}", flush=True)
    print("PROGRES 100", flush=True)
    return 0



def _servi_erreur(mask_bool, gray, true_m, params):
    """Erreur du polygone servi pour UN jeu de
    paramètres, depuis un masque déjà calculé —
    la mesure du tournoi (même chaîne que le
    bulletin : mask_to_polygon puis chamfer
    contre le tracé de référence)."""
    servi = mask_to_polygon(mask_bool, gray=gray,
                            params=params)
    if servi is None:
        return None
    servi_m = np.asarray(rasterize(servi),
                         dtype=np.uint8)
    return round(chamfer_pct(servi_m, true_m), 2)


# Bornes des paramètres du tournoi (build 143).
TOURNOI_BORNES = {
    "fenetre_pct": (0.8, 4.5),
    "seuil_marche": (6.0, 70.0),
    "bande_bas": (0.35, 0.95),
    "bande_haut": (1.05, 1.7),
    "clip": (1.05, 1.8),
    "dp_eps": (0.0004, 0.005),
}


def _muter(parent, rng):
    """Un enfant : chaque paramètre est multiplié
    par un facteur log-normal (petit pas le plus
    souvent, grand saut parfois), borné."""
    enfant = {}
    for k, v in parent.items():
        lo, hi = TOURNOI_BORNES[k]
        sigma = 0.45 if rng.random() < 0.12 else 0.16
        nv = v * math.exp(rng.gauss(0, sigma))
        enfant[k] = round(min(hi, max(lo, nv)), 4)
    return enfant


def tournoi_seul(args):
    """LE TOURNOI (build 143) : des variantes des
    constantes d'extraction compétitionnent sur
    la base du modèle existant. Les masques sont
    calculés UNE fois ; chaque variante ne rejoue
    que l'extraction. Sélection sur dev + banc
    (l'oracle note contre les élites, les
    variantes ne voient que leur rang) ;
    l'examen strict reste SCELLÉ pendant la
    sélection et ne sert qu'au verdict final,
    une fois. Le tenant (paramètres actifs) n'est
    remplacé que battu : le champion est alors
    écrit dans extraction-champion.json, que
    charger_params lira partout ensuite."""
    import torch
    import datetime
    import random
    import time
    modele = os.path.join(args.sortie,
                          "contours-v0.pt")
    if not os.path.exists(modele):
        print("Tournoi impossible : aucun modèle "
              "(contours-v0.pt) dans le dossier de "
              "sortie — entraînez d'abord le "
              "traceur.", flush=True)
        return 3
    sp = prepare_splits(args.racine)
    sel_items = sp["dev_items"] + sp["banc_items"]
    strict_items = sp["strict_items"] or []
    if len(sel_items) < 4:
        print("Tournoi impossible : pas assez de "
              "photos de sélection (dev + banc).",
              flush=True)
        return 2
    device = pick_device(torch)
    print(f"appareil : {device}", flush=True)
    model = build_model(torch).to(device)
    model.load_state_dict(torch.load(
        modele, map_location=device))
    model.eval()

    def predict_mask(img_pil):
        x = torch.from_numpy(
            np.asarray(img_pil, dtype=np.float32)
            / 255.0).permute(2, 0, 1).unsqueeze(0).to(device)
        with torch.no_grad():
            prob = torch.sigmoid(model(x))[0, 0]
        return prob.cpu().numpy() > 0.5

    print("PHASE Tournoi — calcul des masques…",
          flush=True)
    print("PROGRES 10", flush=True)
    t0 = time.time()

    def prep(items):
        out = []
        for it in items:
            try:
                chemin = sp["resolve"](it["file"])
                img = load_image_modele(chemin)
                gray = np.asarray(
                    Image.open(chemin).convert("L"),
                    dtype=np.float64)
            except Exception:
                continue
            out.append({
                "sn": it["sn"],
                "mask": predict_mask(img),
                "gray": gray,
                "true": np.asarray(
                    rasterize(it["lasso"]),
                    dtype=np.uint8),
            })
        return out

    sel = prep(sel_items)
    ver = prep(strict_items)
    if len(sel) < 4:
        print("Tournoi impossible : photos de "
              "sélection illisibles.", flush=True)
        return 2
    print(f"sélection : {len(sel)} photos · "
          f"strict scellé : {len(ver)} photos",
          flush=True)
    print("PROGRES 25", flush=True)

    def score(params, items):
        if not items:
            return None
        return _servi_score(params, items)

    tenant, source = charger_params(args.sortie)
    parent = dict(tenant)
    parent_score = score(parent, sel)
    tenant_score = parent_score
    print(f"tenant ({source}) : sélection "
          f"{parent_score} %", flush=True)
    rng = random.Random(args.seed)
    historique = [{"gen": 0, "score": parent_score,
                   "params": dict(parent)}]
    G, L = args.generations, args.enfants
    for g in range(1, G + 1):
        print(f"PHASE Tournoi — génération {g}/{G}…",
              flush=True)
        enfants = [(_servi_score(e, sel), e)
                   for e in [_muter(parent, rng)
                             for _ in range(L)]]
        enfants.sort(key=lambda t: t[0])
        meilleur, meilleur_p = enfants[0]
        if meilleur < parent_score - 0.001:
            parent, parent_score = meilleur_p, meilleur
            historique.append({
                "gen": g, "score": parent_score,
                "params": dict(parent)})
        print(f"génération {g}/{G} : meilleur "
              f"enfant {meilleur} % · tenant "
              f"{parent_score} %", flush=True)
        print(f"PROGRES {25 + int(65 * g / G)}",
              flush=True)

    print("PHASE Tournoi — verdict sur l'examen "
          "scellé…", flush=True)
    print("PROGRES 95", flush=True)
    strict_tenant = score(tenant, ver)
    strict_champ = score(parent, ver)
    ameliore = parent_score < tenant_score - 0.001
    rapport = {
        "genere": datetime.datetime.now().strftime(
            "%Y-%m-%dT%H:%M:%S"),
        "appareil": str(device),
        "modele_mtime": (
            datetime.datetime.fromtimestamp(
                os.path.getmtime(modele))
            .strftime("%Y-%m-%dT%H:%M:%S")),
        "seed": args.seed,
        "generations": G,
        "enfants": L,
        "evaluations": G * L + 1,
        "duree_s": round(time.time() - t0, 1),
        "n_selection": len(sel),
        "n_strict": len(ver),
        "tenant": {
            "params": tenant, "source": source,
            "score_selection": tenant_score,
            "score_strict": strict_tenant,
        },
        "champion": {
            "params": parent,
            "score_selection": parent_score,
            "score_strict": strict_champ,
            "nouveau": ameliore,
        },
        "historique": historique,
    }
    out_r = os.path.join(args.sortie,
                         "tournoi-rapport.json")
    with open(out_r, "w") as f:
        json.dump(rapport, f, indent=1, sort_keys=True)
    if ameliore:
        out_c = os.path.join(
            args.sortie, "extraction-champion.json")
        with open(out_c, "w") as f:
            json.dump({
                "params": parent,
                "score_selection": parent_score,
                "score_strict": strict_champ,
                "genere": rapport["genere"],
                "modele_mtime": rapport["modele_mtime"],
            }, f, indent=1, sort_keys=True)
        print(f"CHAMPION : sélection "
              f"{rapport['tenant']['score_selection']}"
              f" → {parent_score} % · strict "
              f"{strict_tenant} → {strict_champ} % "
              f"— constantes écrites dans "
              f"extraction-champion.json", flush=True)
    else:
        print(f"Le tenant garde son titre : "
              f"sélection {parent_score} % · strict "
              f"{strict_tenant} % — aucun fichier "
              f"champion écrit.", flush=True)
    print(f"rapport écrit : {out_r}", flush=True)
    print("PROGRES 100", flush=True)
    return 0


def _servi_score(params, items):
    """Score de sélection d'une variante :
    médiane des erreurs du servi sur les items
    en cache (extraction impossible = 10 %)."""
    vals = []
    for c in items:
        e = _servi_erreur(c["mask"], c["gray"],
                          c["true"], params)
        vals.append(10.0 if e is None else e)
    return round(float(np.median(vals)), 3)



def _servi_erreur_precise(mask_bool, gray, true_m,
                          params):
    """Comme _servi_erreur, mais SANS arrondi :
    le score d'arène du méga-tournoi — sur une
    seule photo, l'arrondi au centième
    recréerait un plateau d'ex æquo."""
    servi = mask_to_polygon(mask_bool, gray=gray,
                            params=params)
    if servi is None:
        return None
    servi_m = np.asarray(rasterize(servi),
                         dtype=np.uint8)
    return float(chamfer_pct(servi_m, true_m))


def _cle_params(params):
    """Clé déterministe d'un jeu de paramètres
    (bris d'égalité stable entre exécutions)."""
    return tuple(params[k] for k in sorted(params))


# Contexte des travailleurs du méga-tournoi :
# rempli par l'initialiseur de chaque processus
# (masque, photo et référence de l'arène,
# calculés une seule fois par le parent).
_MEGA_CTX = {}


def _mega_init(ctx):
    _MEGA_CTX.update(ctx)


def _mega_eval(params):
    """Un enfant du méga-tournoi : extraction
    sur l'arène, score pleine précision (échec
    d'extraction = 10 %)."""
    e = _servi_erreur_precise(
        _MEGA_CTX["mask"], _MEGA_CTX["gray"],
        _MEGA_CTX["true"], params)
    return (10.0 if e is None else e), params


def _mega_echantillon(rng, boite=None):
    """Un candidat tiré uniformément (en log)
    dans une boîte {param: (lo, hi)} — par
    défaut les bornes du tournoi."""
    src = boite or TOURNOI_BORNES
    out = {}
    for k, (lo, hi) in src.items():
        out[k] = round(math.exp(rng.uniform(
            math.log(lo), math.log(hi))), 4)
    return out


def _mega_boite_confiance(evalues, fraction=0.10):
    """La boîte de confiance (build 144) :
    pour chaque paramètre, l'intervalle (en
    log) couvert par le meilleur `fraction`
    des enfants déjà évalués, élargi de 15 %,
    sans jamais descendre sous 30 % de
    l'intervalle d'origine. Les directions qui
    empirent le score sont échantillonnées de
    moins en moins — jamais interdites : une
    valeur mauvaise seule peut être bonne en
    combinaison."""
    if len(evalues) < 200:
        return None
    tries = sorted(
        evalues,
        key=lambda t: (t[0], _cle_params(t[1])))
    n = max(20, int(len(tries) * fraction))
    top = [p for _, p in tries[:n]]
    boite = {}
    for k, (lo, hi) in TOURNOI_BORNES.items():
        llo, lhi = math.log(lo), math.log(hi)
        vals = sorted(math.log(p[k]) for p in top)
        a, b = vals[0], vals[-1]
        marge = 0.15 * (b - a)
        a, b = a - marge, b + marge
        largeur_min = 0.30 * (lhi - llo)
        if b - a < largeur_min:
            m = (a + b) / 2
            a, b = (m - largeur_min / 2,
                    m + largeur_min / 2)
        boite[k] = (math.exp(max(llo, a)),
                    math.exp(min(lhi, b)))
    return boite


def _mega_recolte(evalues, cap=40, dist_min=0.12):
    """La récolte : les meilleurs enfants, en
    gardant une distance minimale dans
    l'espace des paramètres normalisé
    (coordonnées log ramenées à [0, 1]) — pas
    40 clones du même point."""
    def z(p):
        return [(math.log(p[k])
                 - math.log(TOURNOI_BORNES[k][0]))
                / (math.log(TOURNOI_BORNES[k][1])
                   - math.log(TOURNOI_BORNES[k][0]))
                for k in sorted(TOURNOI_BORNES)]
    tries = sorted(
        evalues,
        key=lambda t: (t[0], _cle_params(t[1])))
    garde, zs = [], []
    for s, p in tries:
        zp = z(p)
        if all(math.dist(zp, zq) >= dist_min
               for zq in zs):
            garde.append((s, p))
            zs.append(zp)
            if len(garde) >= cap:
                break
    return garde


def _oracle_portefeuille(sortie):
    """Les tenants que l'oracle peut choisir :
    défauts, champion actif (fichier), roi de
    l'arène et gagnant des séries du méga (lus
    dans mega-rapport.json s'il existe)."""
    port = [("défauts", dict(PARAMS_DEFAUT))]
    ch = os.path.join(sortie,
                      "extraction-champion.json")
    if os.path.exists(ch):
        try:
            cj = json.load(open(ch))
            p = {k: float(cj["params"][k])
                 for k in PARAMS_DEFAUT}
            port.append(("champion", p))
        except Exception:
            pass
    mg = os.path.join(sortie, "mega-rapport.json")
    if os.path.exists(mg):
        try:
            mj = json.load(open(mg))
            pa = mj["arene"]["params_meilleur"]
            port.append(("arène-méga",
                         {k: float(pa[k])
                          for k in PARAMS_DEFAUT}))
            pg = mj["gagnant"]["params"]
            port.append(("séries-méga",
                         {k: float(pg[k])
                          for k in PARAMS_DEFAUT}))
        except Exception:
            pass
    return port


def oracle_seul(args):
    """L'ÉCART ORACLE (build 145) : pour chaque
    photo des examens, le meilleur tenant du
    portefeuille, en pleine précision. Mesure
    le plafond d'un sélecteur par photo : si
    l'oracle ne bat le tenant que d'un souffle,
    apprendre à choisir ne vaut pas la peine.
    Ne sélectionne rien, n'écrit aucun
    champion : une mesure, pas un verdict."""
    import torch
    import datetime
    import time
    modele = os.path.join(args.sortie,
                          "contours-v0.pt")
    if not os.path.exists(modele):
        print("Oracle impossible : aucun modèle "
              "(contours-v0.pt) dans le dossier "
              "de sortie — entraînez d'abord le "
              "traceur.", flush=True)
        return 3
    sp = prepare_splits(args.racine)
    device = pick_device(torch)
    print(f"appareil : {device}", flush=True)
    model = build_model(torch).to(device)
    model.load_state_dict(torch.load(
        modele, map_location=device))
    model.eval()

    def predict_mask(img_pil):
        x = torch.from_numpy(
            np.asarray(img_pil, dtype=np.float32)
            / 255.0).permute(2, 0, 1).unsqueeze(0).to(device)
        with torch.no_grad():
            prob = torch.sigmoid(model(x))[0, 0]
        return prob.cpu().numpy() > 0.5

    print("PHASE Oracle — calcul des masques…",
          flush=True)
    print("PROGRES 10", flush=True)
    t0 = time.time()

    def prep(items):
        out = []
        for it in items:
            try:
                chemin = sp["resolve"](it["file"])
                img = load_image_modele(chemin)
                gray = np.asarray(
                    Image.open(chemin).convert("L"),
                    dtype=np.float64)
            except Exception:
                continue
            out.append({
                "sn": it["sn"],
                "mask": predict_mask(img),
                "gray": gray,
                "true": np.asarray(
                    rasterize(it["lasso"]),
                    dtype=np.uint8),
            })
        return out

    def med(vals):
        return round(float(np.median(vals)), 4)

    port = _oracle_portefeuille(args.sortie)
    noms = [n for n, _ in port]
    print("portefeuille : " + ", ".join(noms),
          flush=True)
    ensembles = {}
    for nom_ens, items in (
            ("dev", sp["dev_items"]),
            ("banc", sp["banc_items"]),
            ("strict", sp["strict_items"] or [])):
        par_photo = []
        for c in prep(items):
            erreurs = {}
            for nom_t, params in port:
                e = _servi_erreur_precise(
                    c["mask"], c["gray"], c["true"],
                    params)
                erreurs[nom_t] = (
                    10.0 if e is None
                    else round(e, 4))
            gagnant = min(
                erreurs,
                key=lambda k: (erreurs[k], k))
            par_photo.append({
                "photo": c["sn"],
                "erreurs": erreurs,
                "gagnant": gagnant,
                "oracle": erreurs[gagnant],
            })
        if not par_photo:
            ensembles[nom_ens] = None
            continue
        victoires = {n: 0 for n in noms}
        for p in par_photo:
            victoires[p["gagnant"]] += 1
        ensembles[nom_ens] = {
            "photos": len(par_photo),
            "tenants": {n: med([p["erreurs"][n]
                                 for p in par_photo])
                        for n in noms},
            "oracle": med([p["oracle"]
                           for p in par_photo]),
            "oracle_2": (
                med([min(p["erreurs"]["défauts"],
                         p["erreurs"]["champion"])
                     for p in par_photo])
                if "champion" in noms else None),
            "victoires": victoires,
            "par_photo": par_photo,
        }
        e = ensembles[nom_ens]
        print(f"{nom_ens} : oracle {e['oracle']} %"
              " · tenants " + " · ".join(
                  f"{n} {e['tenants'][n]}"
                  for n in noms), flush=True)
    tous = []
    for s_ in ("dev", "banc"):
        if ensembles.get(s_):
            tous.extend(ensembles[s_]["par_photo"])
    if tous:
        selection = {
            "tenants": {n: med([p["erreurs"][n]
                                 for p in tous])
                        for n in noms},
            "oracle": med([p["oracle"]
                           for p in tous]),
            "oracle_2": (
                med([min(p["erreurs"]["défauts"],
                         p["erreurs"]["champion"])
                     for p in tous])
                if "champion" in noms else None),
        }
    else:
        selection = None
    rap = {
        "genere": datetime.datetime.now().strftime(
            "%Y-%m-%dT%H:%M:%S"),
        "appareil": str(device),
        "modele_mtime": (
            datetime.datetime.fromtimestamp(
                os.path.getmtime(modele))
            .strftime("%Y-%m-%dT%H:%M:%S")),
        "portefeuille": noms,
        "ensembles": ensembles,
        "selection": selection,
        "duree_s": round(time.time() - t0, 1),
    }
    out = os.path.join(args.sortie,
                       "oracle-rapport.json")
    tmp = out + ".tmp"
    with open(tmp, "w") as f:
        json.dump(rap, f, indent=1, sort_keys=True)
    os.replace(tmp, out)
    print(f"rapport oracle écrit : {out}",
          flush=True)
    print("PROGRES 100", flush=True)
    return 0


def mega_seul(args):
    """LE MÉGA-TOURNOI (build 144) : prospection
    massive sur UNE photo-arène (défaut : la
    67, dont l'extraction dégrade un bon
    masque). Des dizaines de milliers d'enfants
    y sont notés en pleine précision contre le
    tracé de référence, en parallèle.
    L'échantillonnage APPREND : chaque enfant
    est archivé (mega-enfants.jsonl), une boîte
    de confiance se resserre sur les régions
    du meilleur décile, des éclaireurs gardent
    l'espace complet ouvert. La récolte (les
    meilleurs enfants DIVERS) affronte ensuite
    toute la sélection (séries), puis l'examen
    strict scellé rend le verdict — comme au
    tournoi. Le rapport est réécrit à chaque
    lot : un arrêt en cours de route laisse sa
    récolte derrière lui."""
    import torch
    import datetime
    import random
    import time
    import multiprocessing as mp
    modele = os.path.join(args.sortie,
                          "contours-v0.pt")
    if not os.path.exists(modele):
        print("Méga-tournoi impossible : aucun "
              "modèle (contours-v0.pt) dans le "
              "dossier de sortie — entraînez "
              "d'abord le traceur.", flush=True)
        return 3
    tenant, source = charger_params(args.sortie)
    sp = prepare_splits(args.racine)
    examens = (sp["dev_items"] + sp["banc_items"]
               + (sp["strict_items"] or []))
    cible = next((e for e in examens
                  if e["sn"] == args.photo), None)
    if cible is None:
        print(f"Méga-tournoi impossible : la "
              f"photo {args.photo} n'est pas "
              f"dans les examens (dev, banc ou "
              f"strict) — l'arène exige un tracé "
              f"de référence hors entraînement.",
              flush=True)
        return 2
    sel_items = sp["dev_items"] + sp["banc_items"]
    strict_items = sp["strict_items"] or []
    if len(sel_items) < 4:
        print("Méga-tournoi impossible : pas "
              "assez de photos de sélection.",
              flush=True)
        return 2
    device = pick_device(torch)
    print(f"appareil : {device}", flush=True)
    model = build_model(torch).to(device)
    model.load_state_dict(torch.load(
        modele, map_location=device))
    model.eval()

    def predict_mask(img_pil):
        x = torch.from_numpy(
            np.asarray(img_pil, dtype=np.float32)
            / 255.0).permute(2, 0, 1).unsqueeze(0).to(device)
        with torch.no_grad():
            prob = torch.sigmoid(model(x))[0, 0]
        return prob.cpu().numpy() > 0.5

    def prep(items):
        out = []
        for it in items:
            try:
                chemin = sp["resolve"](it["file"])
                img = load_image_modele(chemin)
                gray = np.asarray(
                    Image.open(chemin).convert("L"),
                    dtype=np.float64)
            except Exception:
                continue
            out.append({
                "sn": it["sn"],
                "mask": predict_mask(img),
                "gray": gray,
                "true": np.asarray(
                    rasterize(it["lasso"]),
                    dtype=np.uint8),
            })
        return out

    print("PHASE Méga-tournoi — calcul des "
          "masques…", flush=True)
    print("PROGRES 3", flush=True)
    t0 = time.time()
    arene_l = prep([cible])
    if not arene_l:
        print("Méga-tournoi impossible : photo "
              "arène illisible.", flush=True)
        return 2
    arene = arene_l[0]
    sel = prep(sel_items)
    ver = prep(strict_items)

    def score_arene(params):
        e = _servi_erreur_precise(
            arene["mask"], arene["gray"],
            arene["true"], params)
        return 10.0 if e is None else e

    sc_defauts = score_arene(PARAMS_DEFAUT)
    sc_tenant = score_arene(tenant)
    print(f"arène : photo {args.photo} · "
          f"défauts {sc_defauts:.3f} % · tenant "
          f"({source}) {sc_tenant:.3f} %",
          flush=True)

    ctx = {"mask": arene["mask"],
           "gray": arene["gray"],
           "true": arene["true"]}
    W = args.travailleurs
    if W <= 0:
        W = min(10, os.cpu_count() or 2)
    pool = None
    if W > 1:
        try:
            pool = mp.get_context("spawn").Pool(
                processes=W,
                initializer=_mega_init,
                initargs=(ctx,))
        except Exception as ex:
            print(f"parallèle impossible "
                  f"({ex}) — mode séquentiel.",
                  flush=True)
            pool = None
    print(f"travailleurs : "
          f"{W if pool is not None else 1}",
          flush=True)

    rng = random.Random(args.seed)
    budget = max(50, args.budget)
    LOT = 600
    evalues = []
    arch_path = os.path.join(
        args.sortie, "mega-enfants.jsonl")
    archive = open(arch_path, "a")
    rap_path = os.path.join(
        args.sortie, "mega-rapport.json")
    mtime = datetime.datetime.fromtimestamp(
        os.path.getmtime(modele)).strftime(
        "%Y-%m-%dT%H:%M:%S")

    def ecrire_rapport(termine, series=None,
                       gagnant=None, nouveau=False,
                       strict_t=None, strict_g=None):
        recolte = _mega_recolte(evalues)
        meilleur = (min(
            evalues,
            key=lambda t: (t[0],
                           _cle_params(t[1])))
            if evalues else None)
        rap = {
            "genere": datetime.datetime.now()
                .strftime("%Y-%m-%dT%H:%M:%S"),
            "termine": termine,
            "photo": args.photo,
            "appareil": str(device),
            "modele_mtime": mtime,
            "seed": args.seed,
            "budget": budget,
            "evalues": len(evalues),
            "travailleurs":
                W if pool is not None else 1,
            "duree_s": round(time.time() - t0, 1),
            "arene": {
                "defauts": round(sc_defauts, 4),
                "tenant": round(sc_tenant, 4),
                "meilleur":
                    round(meilleur[0], 4)
                    if meilleur else None,
                "params_meilleur":
                    meilleur[1]
                    if meilleur else None,
            },
            "recolte": [
                {"params": p,
                 "score_arene": round(s, 4)}
                for s, p in recolte],
            "series": series,
            "tenant_selection": None,
            "strict": {
                "tenant": strict_t,
                "gagnant": strict_g},
            "nouveau_champion": nouveau,
        }
        if series is not None:
            rap["tenant_selection"] = tenant_sel
            rap["gagnant"] = gagnant
        tmp = rap_path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(rap, f, indent=1,
                      sort_keys=True)
        os.replace(tmp, rap_path)

    faits = 0
    while faits < budget:
        n = min(LOT, budget - faits)
        boite = (_mega_boite_confiance(evalues)
                 if faits >= 2 * LOT else None)
        recolte_c = (_mega_recolte(evalues)
                     if evalues else [])
        moitie = recolte_c[:max(
            1, len(recolte_c) // 2)]
        cands = []
        if faits == 0:
            cands = [dict(PARAMS_DEFAUT),
                     dict(tenant)]
        while len(cands) < n:
            r = rng.random()
            if moitie and r < 0.45:
                parent = dict(
                    rng.choice(moitie)[1])
                cands.append(_muter(parent, rng))
            elif boite is not None and r < 0.80:
                cands.append(
                    _mega_echantillon(rng, boite))
            else:
                cands.append(
                    _mega_echantillon(rng))
        if pool is not None:
            res = list(pool.imap(
                _mega_eval, cands, chunksize=24))
        else:
            _mega_init(ctx)
            res = [_mega_eval(c) for c in cands]
        for s, p in res:
            evalues.append((float(s), p))
            archive.write(json.dumps(
                {"params": p,
                 "score": round(float(s), 5)},
                sort_keys=True) + "\n")
        archive.flush()
        faits += len(res)
        meilleur = min(
            evalues,
            key=lambda t: (t[0],
                           _cle_params(t[1])))
        print(f"prospection : {faits}/{budget} "
              f"· meilleur arène "
              f"{meilleur[0]:.3f} %", flush=True)
        print(f"PROGRES "
              f"{5 + int(70 * faits / budget)}",
              flush=True)
        ecrire_rapport(False)
    archive.close()
    if pool is not None:
        pool.close()
        pool.join()

    print("PHASE Méga-tournoi — séries sur la "
          "sélection…", flush=True)
    print("PROGRES 85", flush=True)
    tenant_sel = _servi_score(tenant, sel)
    series = []
    for s_arene, p in _mega_recolte(evalues):
        series.append({
            "params": p,
            "score_arene": round(s_arene, 4),
            "score_selection": _servi_score(
                p, sel),
        })
    series.sort(key=lambda d: (
        d["score_selection"],
        _cle_params(d["params"])))
    gagnant = series[0] if series else None
    nouveau = bool(
        gagnant
        and gagnant["score_selection"]
        < tenant_sel - 0.001)
    strict_tenant = (_servi_score(tenant, ver)
                     if ver else None)
    strict_gagnant = (
        _servi_score(gagnant["params"], ver)
        if (nouveau and ver) else strict_tenant)
    if nouveau:
        out_c = os.path.join(
            args.sortie, "extraction-champion.json")
        with open(out_c, "w") as f:
            json.dump({
                "params": gagnant["params"],
                "score_selection":
                    gagnant["score_selection"],
                "score_strict": strict_gagnant,
                "genere":
                    datetime.datetime.now()
                    .strftime("%Y-%m-%dT%H:%M:%S"),
                "modele_mtime": mtime,
                "origine":
                    f"mega-photo-{args.photo}",
            }, f, indent=1, sort_keys=True)
    ecrire_rapport(True, series=series,
                   gagnant=gagnant,
                   nouveau=nouveau,
                   strict_t=strict_tenant,
                   strict_g=strict_gagnant)
    if nouveau:
        print(f"NOUVEAU CHAMPION (méga) : "
              f"sélection {tenant_sel} → "
              f"{gagnant['score_selection']} % · "
              f"strict {strict_tenant} → "
              f"{strict_gagnant} % — constantes "
              f"écrites dans "
              f"extraction-champion.json",
              flush=True)
    else:
        print(f"Le tenant garde son titre : "
              f"sélection {tenant_sel} % · "
              f"strict {strict_tenant} % — la "
              f"prospection n'a rien trouvé qui "
              f"se transfère.", flush=True)
    print(f"rapport écrit : {rap_path}",
          flush=True)
    print("PROGRES 100", flush=True)
    return 0


# ---------------- Main ----------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--racine", default=os.path.expanduser(
        "~/Library/Application Support/ScanRecus/Atelier"))
    ap.add_argument("--sortie", default=".")
    ap.add_argument("--epochs", type=int, default=60)
    ap.add_argument("--fabrique",
                    action="store_true",
                    help="fabriquer la banque "
                         "synthétique permanente "
                         "(Atelier/Synthetique) "
                         "puis sortir")
    ap.add_argument("--fonds", type=int,
                    default=6,
                    help="fonds par élite à la "
                         "fabrique (défaut 6)")
    ap.add_argument("--angles", type=int,
                    default=10,
                    help="angles par couple "
                         "reçu × fond à la "
                         "fabrique (défaut 10)")
    ap.add_argument("--limite", type=int,
                    default=0,
                    help="fabrique : nombre max "
                         "d'images NOUVELLES ce "
                         "run (0 = aucune limite ; "
                         "petit nombre = aperçu, "
                         "parents extrêmes d'abord)")
    ap.add_argument("--rotations", type=int,
                    default=0,
                    help="rotations du cadre entier "
                         "par élite (0 = natives "
                         "seules)")
    ap.add_argument("--taille", type=int,
                    default=256,
                    help="œil du traceur : "
                         "résolution d'entrée du "
                         "réseau (défaut 256 — le "
                         "champ « Œil » de "
                         "l'onglet Contours) ; "
                         "bornes 20–1024, arrondie "
                         "au multiple de 4")
    ap.add_argument("--patience", type=int,
                    default=8,
                    help="arrêt anticipé : époques "
                         "de suite sans progrès du "
                         "score de sélection avant "
                         "l'arrêt (défaut 8 — le "
                         "champ « Tolérance » de "
                         "l'onglet Contours)")
    ap.add_argument("--ignorer-synthetiques",
                    action="store_true",
                    help="ne pas charger la banque "
                         "synthétique (case de "
                         "l'onglet Contours)")
    ap.add_argument("--evalue", action="store_true",
                    help="évaluation seule : charge le "
                         "modèle existant et régénère "
                         "le bulletin sans entraîner")
    ap.add_argument("--tournoi", action="store_true",
                    help="tournoi des constantes "
                         "d'extraction : variantes en "
                         "compétition sur dev+banc, "
                         "verdict sur le strict scellé")
    ap.add_argument("--generations", type=int,
                    default=25)
    ap.add_argument("--enfants", type=int,
                    default=16)
    ap.add_argument("--seed", type=int,
                    default=20261027)
    ap.add_argument("--mega", action="store_true",
                    help="méga-tournoi : prospection "
                         "massive sur une "
                         "photo-arène, séries sur "
                         "la sélection, verdict "
                         "sur le strict scellé")
    ap.add_argument("--photo", type=int,
                    default=67,
                    help="photo-arène du "
                         "méga-tournoi")
    ap.add_argument("--budget", type=int,
                    default=100000,
                    help="nombre d'enfants du "
                         "méga-tournoi")
    ap.add_argument("--travailleurs", type=int,
                    default=0,
                    help="processus parallèles "
                         "du méga-tournoi "
                         "(0 = auto)")
    ap.add_argument("--oracle", action="store_true",
                    help="écart oracle : meilleur "
                         "tenant par photo, pleine "
                         "précision (mesure, aucun "
                         "champion écrit)")
    ap.add_argument("--synthetique", action="store_true")
    ap.add_argument("--modele", default=None,
                    help="modèle à charger pour "
                         "--devine (défaut : "
                         "contours-v0.pt de "
                         "--sortie)")
    ap.add_argument("--devine", default=None,
                    help="chemin d'une image : prédit "
                         "son contour et imprime le "
                         "polygone en JSON")
    args = ap.parse_args()
    # L'œil effectif, avant toute dispatch : le
    # réseau descend deux fois (÷4), d'où
    # l'arrondi au multiple de 4.
    global SIZE
    _oeil = max(20, min(1024, int(args.taille)))
    _oeil = ((_oeil + 2) // 4) * 4
    SIZE = _oeil
    print(f"œil du traceur : {SIZE}×{SIZE}",
          flush=True)

    if args.devine:
        return devine(args.devine, args.sortie,
                      args.modele)

    print("PHASE Chargement des élites…", flush=True)
    rng = np.random.default_rng(13)

    if args.evalue:
        if args.synthetique:
            print("Le mode évaluation seule exige "
                  "un modèle entraîné : pas de mode "
                  "synthétique.", flush=True)
            return 2
        return evaluer_seul(args)

    if args.tournoi:
        if args.synthetique:
            print("Le tournoi exige un modèle "
                  "entraîné : pas de mode "
                  "synthétique.", flush=True)
            return 2
        return tournoi_seul(args)

    if args.mega:
        if args.synthetique:
            print("Le méga-tournoi exige un "
                  "modèle entraîné : pas de "
                  "mode syntétique.", flush=True)
            return 2
        return mega_seul(args)

    if args.oracle:
        if args.synthetique:
            print("L'écart oracle exige un "
                  "modèle entraîné : pas de "
                  "mode synthétique.", flush=True)
            return 2
        return oracle_seul(args)

    if args.fabrique:
        return fabriquer_banque(
            args.racine,
            fonds_par_elite=args.fonds,
            angles=args.angles,
            limite=args.limite)

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
        sp = prepare_splits(args.racine)
        elites = sp["elites"]
        resolve = sp["resolve"]
        pool = sp["pool"]
        banc_items = sp["banc_items"]
        strict_items = sp["strict_items"]
        photos_pool = sp["photos_pool"]
        dev_photos = sp["dev_photos"]
        train_elites = sp["train_elites"]
        dev_items = sp["dev_items"]
        print(f"élites : {len(elites)} au total · "
              f"{len(pool)} hors examen · "
              f"{len(banc_items)} au banc · "
              f"{len(strict_items)} au strict",
              flush=True)
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
        X, Y = build_dataset(train_elites, resolve, rng,
                         rotations=args.rotations)
        if X is None:
            print("Aucune image lisible.", flush=True)
            return 2
        if args.ignorer_synthetiques:
            synth_banque = None
            synth_info = {"n": 0, "ignore": True}
            print("banque synthétique : ignorée "
                  "(case cochée)", flush=True)
        else:
            synth_banque = charger_banque_synth(
                args.racine)
            synth_info = None
        if synth_banque is not None:
            Xs, Ys = synth_banque
            X = np.concatenate([X, Xs])
            Y = np.concatenate([Y, Ys])
            synth_info = {"n": int(len(Xs))}
            print(f"banque synthétique : "
                  f"{len(Xs)} images ajoutées "
                  f"à l'entraînement",
                  flush=True)
        for it in (dev_items + banc_items
                   + strict_items):
            it["_img"] = None
        print("PHASE Entraînement du traceur…",
              flush=True)
        charger_params(args.sortie)
        import datetime
        model, bulletin = train_and_eval(
            (X, Y), dev_items, banc_items,
            resolve=resolve, epochs=args.epochs,
            strict_items=strict_items,
            patience=args.patience,
            dossier_archives=os.path.join(
                args.sortie, "archives",
                datetime.datetime.now().strftime(
                    "course-%Y%m%d-%H%M%S")))
        bulletin["synthetique"] = False
        bulletin["synthetique"] = synth_info
        bulletin["rotations"] = args.rotations
        bulletin["taille"] = SIZE
        bulletin["n_train_elites"] = len(train_elites)
        bulletin["n_train_photos"] = (
            len(photos_pool) - len(dev_photos))
        bulletin["dev_photos"] = sorted(dev_photos)
        bulletin["strict_groupes"] = \
            sp["strict_groupes"]
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
