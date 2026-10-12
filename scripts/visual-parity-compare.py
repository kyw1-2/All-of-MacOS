#!/usr/bin/env python3
"""Compare *user-captured* CleanShot/AOM macOS UI PNGs without executing either app.

Usage: python3 scripts/visual-parity-compare.py --reference /path/cleanshot --candidate /path/aom --output /path/parity
Identically named PNGs must correspond to the same display, scale, locale, theme and interaction state.
Pixel similarity is NOT behavioral equivalence.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image

def compare(ref: Path, current: Path, output: Path, tolerance: int) -> dict:
    with Image.open(ref) as im: a = np.asarray(im.convert("RGBA"), dtype=np.int16)
    with Image.open(current) as im: b = np.asarray(im.convert("RGBA"), dtype=np.int16)
    result = {"case": ref.name, "reference_size": list(a.shape[1::-1]),
              "candidate_size": list(b.shape[1::-1])}
    if a.shape != b.shape:
        result.update({"status": "size_mismatch", "pixel_similarity": None})
        return result
    # Composite each RGBA image on an identical opaque background for a
    # visible comparison, while detecting alpha-only differences separately.
    def composite(x: np.ndarray) -> np.ndarray:
        alpha = x[:, :, 3:4].astype(np.float64) / 255.0
        return np.rint(x[:, :, :3] * alpha + 255.0 * (1.0-alpha)).astype(np.int16)
    visible = np.abs(composite(a)-composite(b))
    alpha = np.abs(a[:,:,3]-b[:,:,3])
    mismatch = (visible.max(axis=2)>tolerance) | (alpha>tolerance)
    heat = (np.clip(visible.max(axis=2) * 3,0,255)).astype(np.uint8)
    output.mkdir(parents=True, exist_ok=True)
    Image.fromarray(heat, mode="L").save(output / (ref.stem + ".difference.png"))
    h,w=a.shape[:2]
    result.update({"status": "compared", "pixels": int(h*w),
                   "mismatch_pixels": int(mismatch.sum()),
                   "pixel_similarity": round(float(1.0-mismatch.mean()), 7),
                   "average_channel_difference": round(float(visible.mean()), 5),
                   "max_channel_difference": int(visible.max()),
                   "alpha_mismatch_pixels": int((alpha>tolerance).sum())})
    return result

def main() -> int:
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--reference",required=True,type=Path)
    p.add_argument("--candidate",required=True,type=Path)
    p.add_argument("--output",required=True,type=Path)
    p.add_argument("--tolerance",type=int,default=12)
    args=p.parse_args()
    if not 0<=args.tolerance<=255: p.error("tolerance must be between 0 and 255")
    if not args.reference.is_dir() or not args.candidate.is_dir():
        p.error("Both inputs must be existing directories")
    names=sorted(set(f.name for f in args.reference.glob("*.png"))
                 | set(f.name for f in args.candidate.glob("*.png")))
    if not names: p.error("No PNGs found")
    args.output.mkdir(parents=True,exist_ok=True)
    findings=[]
    for name in names:
        a=args.reference/name; b=args.candidate/name
        if not a.exists() or not b.exists():
            findings.append({"case":name,"status":"missing_pair","pixel_similarity":None})
            continue
        findings.append(compare(a,b,args.output,args.tolerance))
    scores=[x["pixel_similarity"] for x in findings if x["status"]=="compared"]
    report={"tolerance":args.tolerance,"cases":len(findings),
            "compared":len(scores),"unmatched":sum(x["status"]!="compared" for x in findings),
            "mean_pixel_similarity":round(sum(scores)/len(scores),7) if scores else None,
            "worst_case_similarity":min(scores) if scores else None,
            "warning":"Pixel similarity is not a functional parity score; a 99% threshold does not prove 99% application equivalence.",
            "findings":findings}
    (args.output/"comparison.json").write_text(json.dumps(report,indent=2)+"\n")
    print(json.dumps({k:v for k,v in report.items() if k!="findings"},indent=2))
    return 0 if report["unmatched"]==0 else 1

if __name__=="__main__":
    raise SystemExit(main())
