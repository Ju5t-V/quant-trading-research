"""Break down the 2020-2022 tester deals by year/month."""
import pandas as pd

df = pd.read_csv(r"E:\Documents\Quant Trading\MT5\deals_2020.csv")
# keep position-closing deals only
df = df[df["Direction"].astype(str).str.strip() == "out"].copy()
for col in ("Profit", "Volume"):
    df[col] = pd.to_numeric(df[col].astype(str).str.replace(" ", "", regex=False), errors="coerce")
df["Time"] = pd.to_datetime(df["Time"], format="%Y.%m.%d %H:%M:%S", errors="coerce")
df = df.dropna(subset=["Time", "Profit"])
print(f"Closed trades: {len(df)}, total P/L: {df['Profit'].sum():,.0f}")

df["year"] = df["Time"].dt.year
print("\nBy YEAR ($):")
print(df.groupby("year")["Profit"].agg(["count", "sum", "mean"]).round(1).to_string())

df["ym"] = df["Time"].dt.to_period("M")
m = df.groupby("ym")["Profit"].agg(["count", "sum"]).round(0)
m["cum"] = m["sum"].cumsum().round(0)
print("\nBy MONTH ($):")
print(m.to_string())

# volume through time (auto-lot shrinks as balance falls)
print("\nAvg lot by year:", df.groupby("year")["Volume"].mean().round(2).to_dict())
