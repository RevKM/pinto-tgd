## Full formula (daily)

```
H  = 100 · Q · (0.15·G + 0.15·P + 0.45·T + 0.25·K)
Q  = min(1, 2·T)
E  ≈ 40 / √N
trend = H today − H of 7 days ago

G  = 0.6·G1 + 0.4·G2
G1 = min(1, median(g) / 0.6)
G2 = 1 − min(1, (top(g) − median(g)) / 0.4)
g  = (ilvl − lo(L)) / (hi(L) − lo(L)), limited to 0..1

P  = 0.7·P1 + 0.3·P2
P1 = median(p)
P2 = share of professions with D or more members at p ≥ 0.75
p  = skill / cap(L)
D  = max(1, round(log10(N)))

T  = 0.40·T1 + 0.35·T2 + 0.25·T3
T1 = min(1, median(d) / 0.5)
T2 = min(1, median(n) / (4·log10(N)))
T3 = min(1, M / 0.4)

K  = 0.7·K1 + 0.3·K2
K1 = mean(k)
k  = c · (0.3 + 0.7·b)
c  = min(1, s / 3)
b  = 1 if the member has a bridge day in the last 7 days, else 0
K2 = R / N

w  = 0.96 · w_prev + (sum of a for today)
z  = 1.8 · (1 − 0.96^t)                     (tie when w ≥ z)
a  = 1 (dungeon), 0.5 (quest group), 0.25 (raid)

N  = members online on 2 or more of the last 7 days
```

Calculate H each day. The values d, M, b, and N use the last 7 days.

## Key

**Guild level**

| Letter | Meaning |
|---|---|
| H | Health score of the guild for the week, 0 to 100 |
| E | Uncertainty band of H (larger than before, because one week has less data) |
| Q | Gate that decreases H when T is less than 0.5 |
| N | Number of active members (online on 2 or more days in the week) |
| G | Gear part. G1 is the gear level, G2 is the race check |
| P | Profession part. P1 is the skill level, P2 is the coverage |
| T | Together part. T1 is group play, T2 is breadth, T3 is mixed groups |
| K | Crew and bridge part. K1 is the member mean, K2 is the connection of the guild |
| D | Number of skilled members necessary to cover one profession |
| M | Share of guild groups this week with a member from the oldest third and the newest third, by join date |
| R | Number of members in the largest group that ties connect |
| t | Number of weeks for which you have data |
| z | Tie threshold. It starts at 0.5 in week 1 and increases to 2 |

**Member level**

| Letter | Meaning |
|---|---|
| g | Gear progress of the member, adjusted for character level |
| ilvl | Item level of the member at the end of the week |
| L | Character level |
| lo(L), hi(L) | Lowest and highest usual ilvl at level L |
| top(g) | 90th percentile of g in the guild |
| p | Profession progress of the member |
| skill | Profession skill of the member (the mean, if more than one) |
| cap(L) | Maximum skill possible at level L |
| d | Guild group days divided by play days, this week |
| n | Number of ties of the member |
| s | Crew size (the strongest ties, 4 at most) |
| c | Crew score |
| b | Bridge score, 0 or 1 |
| k | Crew and bridge score of the member |

**Pair level**

| Letter | Meaning |
|---|---|
| w | Tie strength between two members, with memory |
| w_prev | Tie strength of last week (0 in week 1) |
| a | Activity weight of one shared group day |
