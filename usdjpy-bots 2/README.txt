USD/JPY ALGORITHMIC TRADING BOTS
=================================

Two weeks in the summer of 2026 trying to automate a prop-firm USD/JPY
account. The setup: MetaTrader 5 and its Strategy Tester, The5ers demo
($10k, 1:33), MQL5 for the bots. Research in Python 3.13 on Anaconda and
Jupyter: pandas and numpy for the heavy lifting, matplotlib for the
charts, tqdm for watching progress bars at 6 seconds per seed, parquet
and pickle caches to survive kernel deaths. Later, VMware Fusion, a
Windows 11 evaluation VM and Tickstory Lite, in pursuit of real ticks.
Free tick CSVs from HistData.com — 3.5 years, 880 trading days, 17.5
million rows — which turned out to be 1-second bar snapshots wearing a
tick costume. Maximum tick density in the dataset: 1.0.

Results along the way included a +101% two-year return, a Sharpe of
2.53, and a max drawdown so tidy it looked like it had been ironed —
all of which should be read with the paragraphs on either side firmly
in mind.

On the execution side, The5ers demo feed is not a live ECN — it is a
replay environment with airbrushed spreads, no real latency, and tick
density that flatters every strategy that depends on it. The fairy tale
was technically coherent. The plumbing was not.

The philosophy regardless: one idea at a time, finish it, and if you
wouldn't bet your own money on it, don't claim edge. Year-by-year
testing, 500-seed Monte Carlo for anything random, post-cost everything.

The typology of bots that emerged:

  Postman       — makes small consistent profit every session, like a
                  salary delivery. The target. Never achieved.

  Vacuum Cleaner — medium frequency, medium moves, steady compounding.
                  Achieved briefly, then the data quality caught up.

  Lottery Ticket — rare entries, wide TP, sits dormant then catches one
                  giant move. Spikey lives here. The only typology that
                  held up — because macro events don't care about tick
                  resolution.

  Drunkard      — random direction, session-hold, ATR geometry. Also
                  Kung Fu Master, because Zui Quan looks like chaos
                  and allegedly hides real technique. Jury still out.

And the vocabulary:

  Catwalk       — the equity curve a backtest must show to earn further
                  attention.

  Seed 42       — the lucky random seed that produced an all-green
                  four-year backtest before the 500-seed Monte Carlo
                  politely explained that 489 other seeds disagreed.

  The MD likes trades — statistical validity requires volume. 11 trades
                  is anecdote.

What Survives
  Spike reversion rate (63-67%, regime-invariant, causally clean,
  currently untradeable after costs but the most robust finding).
  M1 grid coordination effect (on-grid edge; off-grid: -1.29/trade).
  Drunkard geometry (64.2% pct_pos on random entries, confirmed in
  Tester — a real chassis waiting for a real direction signal).

Next
  Real Dukascopy ticks via Tickstory Lite. Rebuild velocity. Rebuild
  Rainmaker. Attach signal to Drunkard. Find out if the Kung Fu master
  actually knows what he is doing, or just got lucky in 2026.

==========================================================================

SpikeCatcher v7.4 "Spikey 11K"                  SpikeCatcher_v7_4.mq5
  +101% over 2 years, PF 7.88, 11 trades, catwalk equity curve.
  Three macro events drove it. Beautiful and statistically thin.

SpikeCatcher v7.6                               SpikeCatcher_v7_6.mq5
  Added regime filter. +60%, PF 2.60, 25 trades. More honest.

Rainmaker v1.0                                  Rainmaker_v1_0.mq5
  Persistence-momentum engine. Python said +2.23 pip/trade.
  Tester said 28% win rate. A lookahead bug had been using bar open
  instead of bar close. Fixed: -1.13. Filed under lessons.

Monkey v2.0                                     Monkey_v2_0.mq5
  If price went up, buy. Result: -0.95 pip/trade, every year.
  The opposite: -0.80. Kept as a reminder.

Postman v1.0                                    Postman_v1_0.mq5
  The daily-salary attempt. Reads the raw tick tape for a two-burst
  pattern: silence, a fast one-way burst, a short pause, a second
  burst in the same direction. Enters on burst two with a 0.8-pip
  stop, trails after 60 seconds, out by 180. Tue-Thu, London-NY
  overlap only. Lived entirely on millisecond gaps between ticks —
  exactly what 1-second data can't see, the MT5 Tester synthesizes,
  and a retail connection can't react to in time. Hence the typology
  entry above: never achieved.

Reverso v1.0                                    Reverso_v1_0.mq5
  The 63-67% spike reversion finally given a body. Fade any M1 bar
  2.5x the 20-bar average range; TP at half the spike, SL at 0.3 of it,
  both sized to that spike. Python on real Dukascopy ticks: +88.7 pips
  over 667 trades in Q1 2026, and barely dented at realistic reaction
  speed (+0.133 -> +0.115 per trade) — the first idea in the project
  that didn't need superhero reflexes. Then the catch: a market order
  fired at the moment of detection pays the widest spread of the day,
  and on the soft-play demo feed that was enough to sink it. Proving
  the edge needs paid low-latency access and a real feed.

Drunkard v3.2  [the Kung Fu Master]             Drunkard_v3_2.mq5
  Random direction. Literally a coin flip. ATR-normalized TP at 150x,
  SL at 10x. One trade per day, close at 16:00. Streak memory for fun.
  The geometry alone — no signal — is profitable across 64% of 500
  random seeds. Fat tails do the work. In 2026: +35%, Sharpe 2.53,
  PF 1.24, 238 trades. Over the full 3.5 years: -32%. The 2023 regime
  was choppy and the wide TP never fired enough to cover the stops.
  Real moves. Wrong fight, some days.

The Twist
  Somewhere around week two it emerged that HistData "tick" files are
  1-second bar snapshots. Maximum tick density: 1.0. Always. Three
  hours and one Windows 11 virtual machine later, Tickstory Lite
  connected to Dukascopy and said "Successful." First confirmed real
  tick:
    20120213 02:04:10:332,1.24243,1.24262
  The :332 is 332 milliseconds. The fairy tale paused here.

--
MT5 every-tick backtests. Python on HistData CSVs (see The Twist).
No guarantees. No live capital was harmed.
