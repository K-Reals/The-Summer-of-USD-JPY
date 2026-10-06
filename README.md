# The-Summer-of-USD-JPY

USD/JPY ALGORITHMIC TRADING BOTS
=================================

Two weeks in the summer of 2026 trying to automate a prop-firm USD/JPY
account. 

The setup: Claude for vibe coding, teaching, and strategizing, MetaTrader 5 and its built-in Strategy Tester 
for backtest and optimization, The5ers demo ($10k, 1:33, used mainly at 1:10) for the feed and trades, 
MQL5 for the bots. 

Research in Python 3.13 on Anaconda and Jupyter: pandas and numpy for the heavy lifting, 
matplotlib for the charts, tqdm for watching progress bars at 6 seconds per seed, parquet
and pickle caches to survive kernel deaths. 

**RESULTS**

Results along the way included a +101% two-year return, a Sharpe of
2.53, and a 2.5% max drawdown so tidy it looked like it had been ironed!

All of which should be read with a grain of salt.

Because The5ers demo feed is not a live ECN — it is a
replay environment with airbrushed spreads, no real latency, and tick
density that flatters every strategy that depends on it. 

Because free tick CSVs from HistData.com — 3.5 years, 880 trading days, 17.5
million rows — turned out to be 1-second demo bar snapshots. 

Because Python runs did not include realistic "basic" latency (the one MT5 does not charge for), 
and high-speed edges evaporated irl.

The philosophy regardless: one idea at a time, finish it, and if you
wouldn't bet your own money on it, don't claim edge. Year-by-year
testing, 500-seed Monte Carlo for anything random, post-cost everything. 

Some bots were pure philosophical bets: e.g. Monkey bought and sold randomly 
but tried to maintain S/L discipline. Over time, this produced nothing.

What survived thus far: 

- Spike reversion rate (63-67%, regime-invariant, causally clean,
currently untradeable on retail latency and costs but the most robust finding).
 
- M1 grid coordination effect (on-grid edge; off-grid: -1.29/trade).
 
- Drunkard extreme geometry (64.2% pct_pos on random entries, confirmed in Tester — 
a real chassis waiting for a real direction signal).

**THE BOTS**

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

  The MDs like trades — statistical validity requires volume. 11 trades
  is anecdote.

**WHAT NEXT**

  Real Dukascopy ticks via Tickstory Lite. Rebuild velocity. Rebuild
  Rainmaker. Attach signal to Drunkard. Find out if the Kung Fu master
  actually knows what he is doing, or just got lucky in 2026.

==========================================================================

**MORE BOT SPECS**

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
