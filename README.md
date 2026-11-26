# Bar Marino

Family game of the school financial-education project (version 4c). The game itself is in Italian; everything on the research side (database, data, panel) is in English.

- **Game:** https://barmarino.github.io/gioco/ — personal link for a family: `https://barmarino.github.io/gioco/?f=CODE`
- **Researcher panel:** https://barmarino.github.io/gioco/#panel (email and password of a Supabase user whose email is in the `researchers` table)

## How it works

- `index.html` is the whole game in one file. Fonts and the Supabase client are inside it, so phones only talk to GitHub Pages and Supabase.
- Data are on Supabase (EU project, Frankfurt). The database structure, access rules and the two functions families use (`enter_game`, `save_game`) are in `supabase/setup.sql`.
- The database holds no names and no treatment arm, only codes. The code ↔ name key stays with the team.
- `index.html` contains Supabase's *publishable* key, which is meant to be public. The secret key and the database password never go here.

## Adding a researcher

1. Supabase > Authentication > Users > **Add user > Create new user**: their email, a temporary password, *Auto Confirm User* ticked. (Not "Send invitation": on the free plan Supabase only emails members of the Supabase team, and the panel has no page for invitation links.)
2. Supabase > SQL Editor: `insert into public.researchers (email) values ('their.email@unibocconi.it');`
3. Send them the panel link and the temporary password through a separate channel. Once signed in, they choose their own password with **Change password** at the bottom of the panel.

To remove someone: delete their row from `researchers` (they lose access to the data immediately) and delete the user in Authentication.

## Data

The panel exports two CSV files, computed from the stored games (scores and dice are recomputed from the choices and each family's dice code):

- **one row per decision:** `family_code, school, seed, mirrored_dice, n, week, decision, type, option, option_label, seconds, selections, chosen_at, die, outcome, amount, shock_seen, prev_week_outcomes`
- **one row per family:** progress, activity, `financial_part`, `dice_total`, `final_net_worth`, `expected_net_worth`, and one column per decision (`d01_grinder` … `d20_mixed_w4`) with the option number.

Decision names and option codes are in the spreadsheet "Bar Marino: decisions and what they measure" (column *Dataset variable* and *Dataset values*). Times are UTC.

## Updating the game

Replace `index.html` with the new version: GitHub Pages publishes it within a couple of minutes. Every version stays in the commit history, so it is always known which version was online at any time.
