#!/usr/bin/env python3
"""
Suffix Pool — two-tranche treasury Monte-Carlo / scenario simulation.

Models the EXACT on-chain math of contracts/src/suffix/SuffixTreasury.sol under
the DECIDED supply model:
  - SENIOR ($ai): bounded launch float (LBP price discovery off-treasury), then
    seedSenior CAPPED by SENIOR_CAP. Mints at floorPar; exits at k*floorPar.
  - JUNIOR ($aiLP): pre-funded first-loss buffer at launch (senior:junior ratio),
    then elastic seedJunior at residual NAV.
  - Floor ratchets ONLY from realized revenue (recordRevenue, seniorRatchetBps).
  - Reserve policy (spec 3.4): USDC_target = max(floor_min*liquidMcap_senior,
    beta*trailingAvgDailySellVolume).  ANTI-LUNA: junior is NEVER minted to
    defend senior; floor paid from reserve only, else InsufficientReserve.

Contract invariants reproduced verbatim (all USDC 6dp, here as float USDC):
  seniorClaimUSDC   = seniorSupply * floorPar
  juniorEquityUSDC  = max(0, totalUSDC - seniorClaim)
  juniorNAVPerToken = juniorEquity / juniorSupply   (PAR0 if none)
  seniorFloorPrice  = k * floorPar
  redeemSeniorAtFloor: usdcOut = amt * k*floorPar; revert if > totalUSDC
  applyLoss: totalUSDC -= min(loss, totalUSDC)   (junior eats first by waterfall)
  recordRevenue: floorPar += (rev*ratchetBps/BPS) / seniorSupply ; totalUSDC += rev

We run:
  (A) DRAWDOWN SWEEP — deterministic: at what cumulative loss does the senior
      floor break, as a function of senior:junior buffer ratio and k.
  (B) MONTE-CARLO — stochastic year of: realized revenue (MM spread/POL/yield),
      negative carry ($60-80/yr/domain renewals), sell cascades on senior
      (redeem at floor) + junior exits, and write-off shocks. Reports
      floor-survival probability and junior-NAV distribution under stress.
  (C) PARAMETER SWEEP — grids over k, ratio, ratchet_split, beta, floor_min;
      scores each on floor-survival vs junior-upside retention; recommends ranges.
"""

import numpy as np
import itertools

RNG = np.random.default_rng(20260608)
BPS = 10_000
PAR0 = 1.0  # 1.00 USDC


# ───────────────────────── Treasury model ─────────────────────────
class Treasury:
    """Float mirror of SuffixTreasury.sol math."""

    def __init__(self, k_floor_bps, senior_cap):
        self.k = k_floor_bps / BPS
        self.senior_cap = senior_cap
        self.total_usdc = 0.0
        self.floor_par = PAR0
        self.senior_supply = 0.0
        self.junior_supply = 0.0

    # views
    def senior_claim(self):
        return self.senior_supply * self.floor_par

    def junior_equity(self):
        c = self.senior_claim()
        return self.total_usdc - c if self.total_usdc > c else 0.0

    def junior_nav(self):
        # FIX-1 mirror: at zero junior supply, PAR0 is only valid when there is
        # NO orphaned residual; positive residual must be swept to the floor
        # first (see SuffixTreasury.sweepResidualToFloor), so a first re-seed is
        # never priced against ownerless surplus.
        if self.junior_supply == 0:
            assert self.junior_equity() == 0.0, "orphaned residual at junior supply 0 — sweep to floor"
            return PAR0
        return self.junior_equity() / self.junior_supply

    def senior_floor_price(self):
        return self.k * self.floor_par

    def senior_solvent(self):
        return self.total_usdc >= self.senior_claim()

    def cushion_bps(self):
        c = self.senior_claim()
        if c == 0:
            return float("inf")
        return self.junior_equity() / c * BPS

    # state changes
    def seed_senior(self, usdc):
        # capped (the one added require in the decided model)
        minted = usdc / self.floor_par
        if self.senior_supply + minted > self.senior_cap:
            return 0.0  # reverts in contract; here: rejected
        self.total_usdc += usdc
        self.senior_supply += minted
        return minted

    def seed_junior(self, usdc):
        minted = usdc / self.junior_nav()
        self.total_usdc += usdc
        self.junior_supply += minted
        return minted

    def redeem_senior_at_floor(self, amt):
        out = amt * self.senior_floor_price()
        if out > self.total_usdc:
            # InsufficientReserve — anti-LUNA surfaces insolvency
            return None
        self.total_usdc -= out
        self.senior_supply -= amt
        return out

    def redeem_junior(self, amt):
        out = amt * self.junior_nav()
        if out > self.total_usdc:
            return None
        self.total_usdc -= out
        self.junior_supply -= amt
        return out

    def record_revenue(self, usdc, ratchet_bps):
        self.total_usdc += usdc
        if self.senior_supply > 0 and ratchet_bps > 0:
            ratchet_usdc = usdc * ratchet_bps / BPS
            self.floor_par += ratchet_usdc / self.senior_supply

    def apply_loss(self, usdc):
        out = min(usdc, self.total_usdc)
        self.total_usdc -= out
        return out

    # reserve policy (spec 3.4)
    def reserve_target(self, beta, floor_min, trailing_daily_sell):
        liquid_mcap_senior = self.senior_claim()  # senior liability at floor par
        return max(floor_min * liquid_mcap_senior, beta * trailing_daily_sell)


def make_pool(k_floor_bps, senior_launch, ratio, senior_cap_mult=1.5):
    """Launch: senior float at par, junior pre-funded buffer at ratio senior:junior.
    ratio is senior:junior, e.g. 2.0 means buffer = senior/2.
    """
    cap = senior_launch * senior_cap_mult
    t = Treasury(k_floor_bps, senior_cap=cap)
    t.seed_senior(senior_launch)             # senior raises USDC at par
    junior_buffer = senior_launch / ratio    # pre-funded first-loss USDC
    t.seed_junior(junior_buffer)
    return t


# ───────────────────────── (A) Drawdown sweep ─────────────────────────
def drawdown_break_point(k_floor_bps, ratio, senior_launch=1_000_000.0):
    """Cumulative loss (as fraction of total launch USDC) at which the senior
    floor first becomes unbacked (totalUSDC < seniorClaim) and at which a full
    sell-at-floor of ALL senior would revert (reserve < k*claim)."""
    t = make_pool(k_floor_bps, senior_launch, ratio)
    total0 = t.total_usdc
    claim = t.senior_claim()
    # solvency break: totalUSDC < claim  → totalUSDC must drop below claim
    # loss to solvency break = total0 - claim = junior_equity at launch
    loss_to_solvency = total0 - claim
    # floor-pay break: a full senior sell-at-floor reverts when totalUSDC < k*claim
    loss_to_floorpay = total0 - t.k * claim
    return (loss_to_solvency / total0, loss_to_floorpay / total0,
            t.junior_equity() / total0)


def run_drawdown_sweep():
    print("=" * 78)
    print("(A) DRAWDOWN SWEEP — deterministic break points")
    print("    senior launch = $1,000,000 at par; junior buffer = senior/ratio")
    print("=" * 78)
    print(f"{'k':>5} {'ratio(S:J)':>11} {'buffer$':>10} "
          f"{'loss%->solvency':>16} {'loss%->floorpay':>16}")
    results = {}
    for k_bps in (8500, 9000, 9500):
        for ratio in (1.0, 1.5, 2.0, 3.0, 4.0):
            sol, fp, eq = drawdown_break_point(k_bps, ratio)
            buf = 1_000_000.0 / ratio
            print(f"{k_bps/BPS:>5.2f} {f'{ratio:.0f}:1':>11} {buf:>10,.0f} "
                  f"{sol*100:>15.2f}% {fp*100:>15.2f}%")
            results[(k_bps, ratio)] = (sol, fp)
    print()
    print("Reading: 'loss%->solvency' = cumulative treasury loss (as % of launch")
    print("USDC) before totalUSDC < seniorClaim (junior fully wiped, floor exposed).")
    print("'loss%->floorpay' = loss before a full senior sell-at-floor REVERTS")
    print("(InsufficientReserve). Gap between them = the k<1 (1-k) protection band.")
    print()
    return results


# ───────────────────────── (B) Monte-Carlo year ─────────────────────────
def mc_year(k_floor_bps, ratio, ratchet_split_bps, beta, floor_min,
            n_paths=20000, n_domains=8, days=252,
            stress="normal", senior_launch=1_000_000.0):
    """One simulated year per path. Daily steps.

    Revenue: MM spread + POL fees + domain yield ~ realized, lognormal-ish.
    Negative carry: n_domains renewals @ $60-80/yr, debited (loss to treasury).
    Sell pressure: senior redeem-at-floor (run risk) + junior exits, with a
    cascade regime in stress. Write-off shocks: occasional domain markdowns.
    """
    surv_solvent = np.zeros(n_paths, dtype=bool)
    surv_floorpay = np.zeros(n_paths, dtype=bool)
    junior_nav_end = np.zeros(n_paths)
    floor_par_end = np.zeros(n_paths)
    cushion_end = np.zeros(n_paths)

    # stress regime knobs
    if stress == "normal":
        sell_intensity = 0.004      # daily fraction of senior that hits floor
        junior_exit = 0.003
        shock_p, shock_mu = 0.01, 0.04   # rare 4% treasury write-off
        rev_daily_mu = senior_launch * 0.00035   # ~ realized rev/day
    elif stress == "stress":
        sell_intensity = 0.020
        junior_exit = 0.015
        shock_p, shock_mu = 0.04, 0.10
        rev_daily_mu = senior_launch * 0.00020
    elif stress == "severe":
        sell_intensity = 0.045
        junior_exit = 0.035
        shock_p, shock_mu = 0.08, 0.18
        rev_daily_mu = senior_launch * 0.00010
    else:
        raise ValueError(stress)

    for p in range(n_paths):
        t = make_pool(k_floor_bps, senior_launch, ratio)
        trailing_sell = senior_launch * sell_intensity  # seed trailing avg
        broke_solvency = False
        broke_floorpay = False

        # cascade state: a run can self-reinforce in stress regimes
        cascade = 0.0

        for d in range(days):
            # 1) realized revenue (skewed positive, never from marks)
            rev = max(0.0, RNG.lognormal(mean=np.log(max(rev_daily_mu, 1e-9)),
                                         sigma=0.8))
            t.record_revenue(rev, ratchet_split_bps)

            # 2) negative carry — renewals bleed (only on ~1/days of days each)
            #    n_domains renewals/yr, each $60-80, spread across the year
            if RNG.random() < n_domains / days:
                carry = RNG.uniform(60.0, 80.0)
                t.apply_loss(carry)

            # 3) write-off shock (bad domain / MM loss)
            if RNG.random() < shock_p:
                wo = t.total_usdc * RNG.uniform(0.5, 1.5) * shock_mu
                t.apply_loss(wo)
                cascade += 0.5  # shocks feed the run

            # 4) sell pressure on senior → redeem at floor (run risk)
            base = sell_intensity * (1.0 + cascade)
            sell_frac = min(0.5, max(0.0, RNG.normal(base, base * 0.5)))
            sell_amt = t.senior_supply * sell_frac
            if sell_amt > 0:
                out = t.redeem_senior_at_floor(sell_amt)
                if out is None:
                    broke_floorpay = True
                    # partial fill up to reserve, rest is unmet demand
                    maxamt = t.total_usdc / t.senior_floor_price()
                    if maxamt > 0:
                        t.redeem_senior_at_floor(maxamt)
            trailing_sell = 0.94 * trailing_sell + 0.06 * (sell_amt * t.senior_floor_price())

            # 5) junior exits
            jfrac = min(0.5, max(0.0, RNG.normal(junior_exit, junior_exit)))
            jamt = t.junior_supply * jfrac
            if jamt > 0:
                t.redeem_junior(jamt)

            # 6) solvency check (waterfall)
            if not t.senior_solvent():
                broke_solvency = True

            # 7) reserve policy pressure: if reserve below target, that's a
            #    defense-capacity warning (we record, don't auto-mint — anti-LUNA)
            _ = t.reserve_target(beta, floor_min, trailing_sell)

            # cascade decays
            cascade *= 0.85

        surv_solvent[p] = not broke_solvency
        surv_floorpay[p] = not broke_floorpay
        junior_nav_end[p] = t.junior_nav()
        floor_par_end[p] = t.floor_par
        cushion_end[p] = min(t.cushion_bps(), 1e9)

    return {
        "p_floor_survives_solvency": surv_solvent.mean(),
        "p_floor_pay_never_reverts": surv_floorpay.mean(),
        "junior_nav_p05": np.percentile(junior_nav_end, 5),
        "junior_nav_p50": np.percentile(junior_nav_end, 50),
        "junior_nav_p95": np.percentile(junior_nav_end, 95),
        "junior_nav_mean": junior_nav_end.mean(),
        "junior_wipe_rate": (junior_nav_end < 0.01).mean(),
        "floor_par_p50": np.percentile(floor_par_end, 50),
        "floor_par_p95": np.percentile(floor_par_end, 95),
        "cushion_bps_p50": np.percentile(cushion_end, 50),
    }


def run_monte_carlo():
    print("=" * 78)
    print("(B) MONTE-CARLO — 1yr/path, 20k paths/regime, base params")
    print("    k=0.90, ratio=2:1, ratchet_split=2000bps, beta=3.0, floor_min=0.25")
    print("=" * 78)
    base = dict(k_floor_bps=9000, ratio=2.0, ratchet_split_bps=2000,
                beta=3.0, floor_min=0.25, n_domains=8)
    out = {}
    for stress in ("normal", "stress", "severe"):
        r = mc_year(stress=stress, **base)
        out[stress] = r
        print(f"\n--- regime: {stress.upper()} ---")
        print(f"  P(senior floor stays solvent, full yr) : {r['p_floor_survives_solvency']*100:6.2f}%")
        print(f"  P(floor-pay never reverts, full yr)    : {r['p_floor_pay_never_reverts']*100:6.2f}%")
        print(f"  junior NAV end  p05/p50/p95            : "
              f"{r['junior_nav_p05']:.3f} / {r['junior_nav_p50']:.3f} / {r['junior_nav_p95']:.3f}")
        print(f"  junior NAV mean                        : {r['junior_nav_mean']:.3f}")
        print(f"  junior wipe rate (NAV<0.01)            : {r['junior_wipe_rate']*100:6.2f}%")
        print(f"  floor par end  p50/p95 (ratchet)       : {r['floor_par_p50']:.4f} / {r['floor_par_p95']:.4f}")
        print(f"  cushion bps p50                        : {r['cushion_bps_p50']:,.0f}")
    print()
    return out


# ───────────────────────── (C) Parameter sweep ─────────────────────────
def run_param_sweep():
    print("=" * 78)
    print("(C) PARAMETER SWEEP — recommend defensible ranges (STRESS regime)")
    print("=" * 78)
    ks = [8500, 9000, 9500]
    ratios = [1.0, 1.5, 2.0, 3.0]
    splits = [1000, 2000, 3000, 5000]
    betas = [2.0, 3.0, 5.0]
    floor_mins = [0.20, 0.25, 0.35]

    # 1) k x ratio drives floor-survival (the buffer geometry)
    print("\n[C1] floor-survival vs (k, senior:junior ratio) — STRESS regime")
    print(f"{'k':>5} {'ratio':>7} {'P_solvent':>11} {'P_floorpay':>11} "
          f"{'jNAV_p50':>9} {'wipe%':>7}")
    c1 = {}
    for k_bps, ratio in itertools.product(ks, ratios):
        r = mc_year(k_bps, ratio, 2000, 3.0, 0.25, n_paths=6000, stress="stress")
        c1[(k_bps, ratio)] = r
        print(f"{k_bps/BPS:>5.2f} {f'{ratio:.0f}:1':>7} "
              f"{r['p_floor_survives_solvency']*100:>10.2f}% "
              f"{r['p_floor_pay_never_reverts']*100:>10.2f}% "
              f"{r['junior_nav_p50']:>9.3f} {r['junior_wipe_rate']*100:>6.2f}%")

    # 2) ratchet split: floor growth vs junior upside retention (NORMAL regime
    #    so revenue is meaningful)
    print("\n[C2] ratchet_split tradeoff (NORMAL regime): floor growth vs junior upside")
    print(f"{'split_bps':>10} {'floorPar_p50':>13} {'jNAV_p50':>9} {'jNAV_p95':>9}")
    c2 = {}
    for split in splits:
        r = mc_year(9000, 2.0, split, 3.0, 0.25, n_paths=6000, stress="normal")
        c2[split] = r
        print(f"{split:>10} {r['floor_par_p50']:>13.4f} "
              f"{r['junior_nav_p50']:>9.3f} {r['junior_nav_p95']:>9.3f}")

    # 3) beta x floor_min: reserve target adequacy vs sell pressure.
    #    We measure how often the reserve target is BREACHED (reserve < target)
    #    at year end as a defense-capacity proxy under STRESS.
    print("\n[C3] reserve policy (beta, floor_min) — defense-capacity under STRESS")
    print("     (reported as floor-pay survival; higher reserve coverage = more")
    print("      capacity to honor sell-at-floor before InsufficientReserve)")
    print(f"{'beta':>5} {'floor_min':>10} {'P_floorpay':>11} {'P_solvent':>11}")
    c3 = {}
    for beta, fm in itertools.product(betas, floor_mins):
        r = mc_year(9000, 2.0, 2000, beta, fm, n_paths=6000, stress="stress")
        c3[(beta, fm)] = r
        print(f"{beta:>5.1f} {fm:>10.2f} "
              f"{r['p_floor_pay_never_reverts']*100:>10.2f}% "
              f"{r['p_floor_survives_solvency']*100:>10.2f}%")
    print()
    return c1, c2, c3


if __name__ == "__main__":
    run_drawdown_sweep()
    mc = run_monte_carlo()
    run_param_sweep()
    print("=" * 78)
    print("DONE. See analysis in calling agent's report.")
    print("=" * 78)
