# Risk Rules for the $10,000

These rules are the difference between a drawdown and a blown account. They are enforced in code where possible, but you are the last line of defense. Print this. Read it when you're tempted to "just this once".

## The rules

1. **Total risk cap: never lose more than 2% of the account in a single day.** At $10k that's $200. If a day's open positions could lose more than that at their stops, positions are too big.

2. **Position sizing is computed, not felt.** Size = (account × 1%) ÷ (entry price − stop price). The system calculates it; you don't round up because you "feel good" about a trade.

3. **Every position has an exit defined *before* entry.** Either a stop-loss level or a rule-based exit (e.g. "close crosses below the 5-day average"). No trade without a written exit.

4. **Max drawdown circuit breaker: if the account falls 15% from its peak ($8,500 from a $10k peak), stop trading.** Full stop, minimum two weeks. Then review: is the strategy broken, or is this within its historical drawdown range? Resume only at half size.

5. **No leverage. No margin. No options. No shorting.** Not in year one. Every one of these amplifies mistakes before you've learned what your mistakes look like.

6. **Maximum 4 concurrent positions.** Concentration is how small accounts die; over-diversification is how they stagnate. 2–4 positions of 25–50% each (ETFs) fits an EOD swing style at this size.

7. **No overrides.** If the system says sell, you sell. You may *stop the whole system* at any time (that's rule 4), but you may not cherry-pick its signals. An overridden winner teaches you the worst possible lesson.

8. **New strategies earn trust in this order: backtest → paper → 25% size → full size.** Nothing goes live because it "obviously works". Everything is guilty of overfitting until proven otherwise.

9. **Keep 3+ months of living expenses completely outside this account.** Trading money must be money you can lose without changing your life. If the $10k is not that, trade with less.

10. **The journal is mandatory.** Every trade gets logged: date, ticker, size, entry, exit, P&L, and one honest sentence about your state of mind. Reviewed monthly. Your psychology leaks show up here first.

## Why so strict?

The math of losses is asymmetric: lose 50% and you need +100% just to get back to even. A trader who compounds 10% a year for a decade turns $10k into $26k. A trader who makes 40% one year and loses 50% the next has $7k. **Survival is the strategy.** Returns are what happen while you survive.
