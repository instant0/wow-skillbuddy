Skilly 0.3.1 - Craft Advisor
WoW Forever 1.60.1 (Interface 16001)
By faslkjd56

===============================================================================
INSTALL
===============================================================================
Copy the whole "Skilly" folder into:

    World of Warcraft\Interface\AddOns\Skilly\

The folder must contain Skilly.toc next to the .lua files and
Bindings.xml. Then restart WoW or type /reload.

===============================================================================
STATUS OF THIS TEST BUILD
===============================================================================
This is a TEST BUILD. The recommendation engine now works: with a crafting
profession window open, /skilly next, /skilly best and /skilly cheap print a ranked list
in chat.

What is ready to test in 0.3.1:
  - Ranked recommendations for "best skill-up" and "cheapest available"
  - Out-of-pocket costing: materials you already own are free
  - Missing-material list with its source (vendor, AH, as-if, manual)
  - Settings page and saved options
  - "As if owned" material list and safe, read-only price lookup
  - Manual price overrides (/skilly prices) and /skilly debug diagnostics
  - /skilly probe diagnostics for profession and trainer APIs
  - /skilly export: a copyable window with probe and debug output
  - /skilly bank cache for banked crafting reagents (captured when bank opens)
  - /skilly trainer capture for trainer recipe unlock skills
  - Optional companion anchor beside Professions window (feature toggle, default off)
  - Optional auto-advice on compatible profession open (feature toggle, default off)

Coming in a later build:
  - Optional Skilly text/highlight in the trade-skill window and tooltips

===============================================================================
COMMANDS
===============================================================================
  /skilly  or  /skilly next       Show the next recommended craft
  /skilly best                Prefer the best chance of a skill-up
  /skilly cheap               Prefer the cheapest skill-up (default)
  /skilly config              Open the Skilly settings page
  /skilly asif                List materials marked as already owned
  /skilly asif <item>         Mark an item link, item ID, or name as owned
  /skilly asif clear <item>   Remove one entry
  /skilly asif clear all      Remove every entry
  /skilly prices              List manual price overrides
  /skilly prices <item> <c>   Set a manual price, in copper (0 is allowed)
  /skilly prices clear <item> Remove one manual price
  /skilly prices clear all    Remove every manual price
  /skilly bank                Report bank cache age/state (captures only when bank is open)
  /skilly bank clear          Clear the per-character bank cache
  /skilly trainer             Capture recipes from the open crafting trainer
  /skilly trainer clear       Clear captured trainer data
  /skilly debug               Explain the winner and list unpriced near-misses
  /skilly probe               Print profession and trainer API diagnostics to chat
  /skilly export              Open a copyable window with probe + debug output
  /skilly help                List all commands with usage
  /skilly help <command>      Explain one command

<item> can be an item link, an item ID, or an item name. Manual prices win over
every automatic source; clearing one restores automatic lookup.

"As if owned" means: treat this material as free and already on hand. It is
useful when a material is in another bag, on an alt, or simply available to
you. It is stored per account and never changes your bags.

===============================================================================
HOW RECOMMENDATIONS WORK
===============================================================================
Open a crafting profession window, then run /skilly next. Skilly reads the
recipes the client shows and uses the live recipe color as the skill-up chance:
orange is guaranteed, gray gives none, yellow and green use the client's
thresholds when available. Yellow is never guaranteed: on WoW Forever, Silk
Headband (spell 8762) is yellow from 135 to 145, so at skill 138 its chance is
about 70%, not 100%. /skilly debug shows the exact color and chance for the winner.

"Best" mode sorts by skill-up chance. "Cheap" mode sorts by cost per expected
skill point, counting only materials you still need to obtain. Materials you
own are free. Recipes whose missing materials have no reliable price are left
out of cheap mode; /skilly debug lists them so you can add them with /skilly asif.

Equal-color recipes are ordered by material reliability: materials on hand or
from a vendor come before auction-house-only materials. Skilly never buys,
learns, or crafts anything.

===============================================================================
SETTINGS
===============================================================================
Open with /skilly config or Interface > AddOns > Skilly.

  Mode                        Cheapest available skill-up, or best skill-up
  Include bank                Count materials in the bank as on hand
  Assume purchasable mats     Allow missing materials when a real vendor or
                              auction price is known (on by default)
  Results to show             How many recipes to list (1-10)
  Show minimap button         Display the launcher button
  Feature toggles             Per-feature checkboxes for price sources, ranking
                              options, output details, companion anchor, and
                              auto-advice (see Settings > Skilly)

===============================================================================
PRICES
===============================================================================
Skilly only READS price information. It never scans the auction house,
opens other addons' windows, or changes their data.

It can use, when present:
  - Auctionator (full auction-house scan)
  - Auctioneer (only if a usable public API is confirmed)
  - TSM (partial auction-house data)
  - a small bundled table of fixed vendor prices for common reagents

Your own manual prices and "as if owned" entries always win. Otherwise the
LOWEST reliable price wins; the source is used only to break exact ties.
/skilly debug labels each price so you can see where it came from.

===============================================================================
TESTING - PLEASE HELP
===============================================================================
A few things are still unverified in WoW Forever 1.60.1. Chat text cannot be
copied, so use /skilly export instead of /skilly probe for feedback:

1. Open a profession window (Tailoring is a good choice).
2. Type /skilly export and press Enter. A window opens with the text already
   selected. Press Ctrl+C, then paste the whole report with your reply.
3. Close the profession window and run /skilly export once more.
4. Open a crafting trainer and run /skilly trainer, then /skilly export. The
   export should include trainer capture status/count.
5. Optional: enable "Anchor to Professions window" and/or "Auto-advice on
   profession open" in Settings, then reopen the profession window and confirm
   behavior.

Esc or the close button hides the window. Drag its edge to move it. Each report
contains the version, API diagnostics, cache state, and recommendation evidence.

Please also include:
  - the profession and your current skill level,
  - which price addons you have installed
    (Auctionator, TSM, Auctioneer),
  - whether the auction house has been scanned recently.

This tells us which trade-skill API family Forever exposes and whether
Auctioneer has a usable public price API. Please report any chat errors, wrong
prices, or recommendations that do not make sense. Treat recommendations as
advice to check, not as a substitute for looking at the crafting window.

===============================================================================
NOTES
===============================================================================
Settings are stored in WoW's SavedVariables. No manual file editing is
needed. Skilly targets WoW Forever 1.60.1 only; it does not use Retail
mechanics such as item quality or crafting concentration.
