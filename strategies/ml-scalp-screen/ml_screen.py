"""ML scalp screen, XAUUSD M5 — pre-registered walk-forward (see REPORT.md).

Monthly retrain on trailing 12mo (purged at boundary), predict next month.
Label: gross 4-bar forward direction from next-bar open; costs applied in P&L.
Sequential non-overlapping trades; skip signals whose horizon crosses a >60min gap.
Usage: python ml_screen.py <window>   where window in {dev2526, dev2022, hold1619}
"""
import sys
import numpy as np
import pandas as pd
from sklearn.linear_model import LogisticRegression
from sklearn.preprocessing import StandardScaler
from sklearn.pipeline import make_pipeline
import lightgbm as lgb

WINDOWS = {
    "dev2526": ("2025-01-01", "2026-07-18"),
    "dev2022": ("2020-01-01", "2023-01-01"),
    "hold1619": ("2016-01-01", "2020-01-01"),   # ONE look, only if dev passes
}
win = WINDOWS[sys.argv[1]]
EVAL_A, EVAL_B = pd.Timestamp(win[0]), pd.Timestamp(win[1])
H = 4            # horizon bars
COSTS = (0.40, 0.60)
TAUS = (0.55, 0.60, 0.65)

df = pd.read_parquet(r"E:\Documents\Quant Trading\ML_Scalp\data\XAUUSD_M5.parquet")
df = df[["time", "open", "high", "low", "close"]]
df = df[df["time"] >= EVAL_A - pd.DateOffset(months=14)].reset_index(drop=True)

c, h, l, o = df["close"], df["high"], df["low"], df["open"]
lr = np.log(c).diff()
X = pd.DataFrame(index=df.index)
for n in (1, 2, 3, 6, 12, 24):
    X[f"r{n}"] = np.log(c).diff(n)
X["vol12"] = lr.rolling(12).std()
X["vol48"] = lr.rolling(48).std()
for n in (12, 48):
    hi, lo = h.rolling(n).max(), l.rolling(n).min()
    X[f"rngpos{n}"] = ((c - lo) / (hi - lo).replace(0, np.nan)).clip(0, 1)
X["mdist48"] = c / c.rolling(48).mean() - 1
d = c.diff()
up = d.clip(lower=0).ewm(alpha=1 / 14, adjust=False).mean()
dn = (-d.clip(upper=0)).ewm(alpha=1 / 14, adjust=False).mean()
X["rsi14"] = 100 - 100 / (1 + up / dn.replace(0, np.nan))
atr12 = (h - l).rolling(12).mean()
day = df["time"].dt.date
dailyg = df.groupby(day)
dhi = dailyg["high"].transform("max")   # placeholder; true prev-day below
dagg = df.groupby(day).agg(dh=("high", "max"), dl=("low", "min"))
dagg["datr"] = (dagg["dh"] - dagg["dl"]).rolling(14).mean().shift(1)
dagg["pdh"] = dagg["dh"].shift(1)
dagg["pdl"] = dagg["dl"].shift(1)
mm = pd.DataFrame({"day": day}).join(dagg, on="day")
X["atr_ratio"] = atr12 / mm["datr"]
X["dPDH"] = (mm["pdh"] - c) / mm["datr"]
X["dPDL"] = (c - mm["pdl"]) / mm["datr"]
X["bodyfrac"] = (c - o).abs() / (h - l).replace(0, np.nan)
sgn = np.sign(d).fillna(0)
grp = (sgn != sgn.shift()).cumsum()
X["streak"] = sgn * sgn.groupby(grp).cumcount().add(1)
hr = df["time"].dt.hour + df["time"].dt.minute / 60
X["hsin"] = np.sin(2 * np.pi * hr / 24)
X["hcos"] = np.cos(2 * np.pi * hr / 24)
X["dow"] = df["time"].dt.dayofweek

entry = o.shift(-1)
exitp = o.shift(-(H + 1))
fwd = exitp - entry
y = (fwd > 0).astype(int)
gap_ok = (df["time"].shift(-(H + 1)) - df["time"].shift(-1)) <= pd.Timedelta("60min")

valid = X.notna().all(axis=1) & fwd.notna() & gap_ok
print(f"rows {len(df)}, valid {valid.sum()}")

months = pd.period_range(EVAL_A, EVAL_B - pd.Timedelta("1d"), freq="M")
t = df["time"]
preds = {}
for name in ("logit", "lgbm"):
    preds[name] = pd.Series(np.nan, index=df.index)

for m in months:
    m0, m1 = m.start_time, m.end_time
    tr_mask = valid & (t >= m0 - pd.DateOffset(months=12)) & (t < m0 - pd.Timedelta("2h"))
    ev_mask = valid & (t >= m0) & (t <= m1) & (t < EVAL_B)
    if tr_mask.sum() < 5000 or ev_mask.sum() == 0:
        continue
    Xtr, ytr, Xev = X[tr_mask], y[tr_mask], X[ev_mask]
    logit = make_pipeline(StandardScaler(),
                          LogisticRegression(max_iter=1000, C=1.0))
    logit.fit(Xtr, ytr)
    preds["logit"].loc[Xev.index] = logit.predict_proba(Xev)[:, 1]
    gbm = lgb.LGBMClassifier(n_estimators=300, learning_rate=0.05, num_leaves=31,
                             min_child_samples=200, verbose=-1)
    gbm.fit(Xtr, ytr)
    preds["lgbm"].loc[Xev.index] = gbm.predict_proba(Xev)[:, 1]
    print(f"  {m}: train {tr_mask.sum()}, eval {ev_mask.sum()}", flush=True)

def simulate(p, tau, cost):
    trades = []
    i = 0
    idx = df.index[(p.notna()) & valid].tolist()
    idxset = sorted(idx)
    k = 0
    nextfree = -1
    for i in idxset:
        if i < nextfree:
            continue
        pi = p.iloc[i]
        if pi >= tau:
            trades.append(fwd.iloc[i] - cost)
            nextfree = i + H + 1
        elif pi <= 1 - tau:
            trades.append(-fwd.iloc[i] - cost)
            nextfree = i + H + 1
    tr = np.array(trades)
    if len(tr) == 0:
        return None
    w, lo = tr[tr > 0].sum(), -tr[tr <= 0].sum()
    pf = w / lo if lo > 0 else float("inf")
    return len(tr), pf, (tr > 0).mean(), tr.sum()

ndays = (EVAL_B - EVAL_A).days
print(f"\n== {sys.argv[1]}  {EVAL_A.date()} -> {EVAL_B.date()} ==")
for name in ("logit", "lgbm"):
    for tau in TAUS:
        row = f"  {name:5s} tau={tau:.2f}: "
        for cost in COSTS:
            r = simulate(preds[name], tau, cost)
            if r is None:
                row += f"[cost {cost:.2f}: no trades] "
            else:
                n, pf, wr, net = r
                row += (f"[cost {cost:.2f}: n={n} ({n/(ndays/7*5):.1f}/day) "
                        f"PF={pf:.2f} win={100*wr:.0f}% net=${net:+.0f}/oz] ")
        print(row)
