SkillBuddy 0.3.1 - Craft Advisor
WoW Forever 1.60.1 (Interface 16001)
By faslkjd56

===============================================================================
INSTALL
===============================================================================
Copy the whole "SkillBuddy" folder into:

    World of Warcraft\Interface\AddOns\SkillBuddy\

The folder must contain SkillBuddy.toc next to the .lua files and
Bindings.xml. Then restart WoW or type /reload.

===============================================================================
STATUS OF THIS TEST BUILD
===============================================================================
This is a TEST BUILD. The recommendation engine now works: with a crafting
profession window open, /sb next, /sb best and /sb cheap print a ranked list
in chat.

What is ready to test in 0.3.1:
  - Ranked recommendations for "best skill-up" and "cheapest available"
  - Out-of-pocket costing: materials you already own are free
  - Missing-material list with its source (vendor, AH, as-if, manual)
  - Settings page and saved options
  - "As if owned" material list and safe, read-only price lookup
  - Manual price overrides (/sb prices) and /sb debug diagnostics
  - /sb probe diagnostics for profession and trainer APIs
  - /sb export: a copyable window with probe and debug output

Coming in a later build:
  - Recipe unlock hints learned from visiting a crafting trainer
  - Optional SkillBuddy text in the trade-skill window and tooltips

===============================================================================
COMMANDS
===============================================================================
  /sb  or  /sb next       Show the next recommended craft
  /sb best                Prefer the best chance of a skill-up
  /sb cheap               Prefer the cheapest skill-up (default)
  /sb config              Open the SkillBuddy settings page
  /sb asif                List materials marked as already owned
  /sb asif <item>         Mark an item link, item ID, or name as owned
  /sb asif clear <item>   Remove one entry
  /sb asif clear all      Remove every entry
  /sb prices              List manual price overrides
  /sb prices <item> <c>   Set a manual price, in copper (0 is allowed)
  /sb prices clear <item> Remove one manual price
  /sb prices clear all    Remove every manual price
  /sb debug               Explain the winner and list unpriced near-misses
  /sb probe               Print profession and trainer API diagnostics to chat
  /sb export              Open a copyable window with probe + debug output
  /sb help                List all commands with usage
  /sb help <command>      Explain one command

<item> can be an item link, an item ID, or an item name. Manual prices win over
every automatic source; clearing one restores automatic lookup.

"As if owned" means: treat this material as free and already on hand. It is
useful when a material is in another bag, on an alt, or simply available to
you. It is stored per account and never changes your bags.

===============================================================================
HOW RECOMMENDATIONS WORK
===============================================================================
Open a crafting profession window, then run /sb next. SkillBuddy reads the
recipes the client shows and uses the live recipe color as the skill-up chance:
orange is guaranteed, gray gives none, yellow and green use the client's
thresholds when available. Yellow is never guaranteed: on WoW Forever, Silk
Headband (spell 8762) is yellow from 135 to 145, so at skill 138 its chance is
about 70%, not 100%. /sb debug shows the exact color and chance for the winner.

"Best" mode sorts by skill-up chance. "Cheap" mode sorts by cost per expected
skill point, counting only materials you still need to obtain. Materials you
own are free. Recipes whose missing materials have no reliable price are left
out of cheap mode; /sb debug lists them so you can add them with /sb asif.

Equal-color recipes are ordered by material reliability: materials on hand or
from a vendor come before auction-house-only materials. SkillBuddy never buys,
learns, or crafts anything.

===============================================================================
SETTINGS
===============================================================================
Open with /sb config or Interface > AddOns > SkillBuddy.

  Mode                        Cheapest available skill-up, or best skill-up
  Include bank                Count materials in the bank as on hand
  Assume purchasable mats     Allow missing materials when a real vendor or
                              auction price is known (on by default)
  Results to show             How many recipes to list (1-10)
  Show minimap button         Display the launcher button

===============================================================================
PRICES
===============================================================================
SkillBuddy only READS price information. It never scans the auction house,
opens other addons' windows, or changes their data.

It can use, when present:
  - Auctionator (full auction-house scan)
  - Auctioneer (only if a usable public API is confirmed)
  - TSM (partial auction-house data)
  - a small bundled table of fixed vendor prices for common reagents

Your own manual prices and "as if owned" entries always win. Otherwise the
LOWEST reliable price wins; the source is used only to break exact ties.
/sb debug labels each price so you can see where it came from.

===============================================================================
TESTING - PLEASE HELP
===============================================================================
A few things are still unverified in WoW Forever 1.60.1. Chat text cannot be
copied, so use /sb export instead of /sb probe for feedback:

1. Open a profession window (Tailoring is a good choice).
2. Type /sb export and press Enter. A window opens with the text already
   selected. Press Ctrl+C, then paste the whole report with your reply.
3. Close the profession window and run /sb export once more.
4. Open a crafting trainer and run /sb export a third time. With the trainer
   closed, the report should say "trainer window closed - no rows read".

Esc or the close button hides the window. Drag its edge to move it. Each report
contains the version, API diagnostics, and the current recommendation evidence.

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
needed. SkillBuddy targets WoW Forever 1.60.1 only; it does not use Retail
mechanics such as item quality or crafting concentration.
