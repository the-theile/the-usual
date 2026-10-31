-- The Usual — 0002: visibility helpers, bar-day maths, invite code words
-- Helpers live in schema "private", which PostgREST does not expose, so nobody can
-- call e.g. is_blocked() directly to find out whether they were blocked.

-- ===== Visibility =====

create or replace function private.is_blocked(b uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.blocks
    where bartender_id = b and regular_id = (select auth.uid())
  )
$$;

create or replace function private.is_connected(b uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.connections
    where bartender_id = b and regular_id = (select auth.uid())
  )
$$;

-- Posts, photos: yourself, or a connected regular who is not blocked.
create or replace function private.can_view_bartender(b uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select b is not null and (
    b = (select auth.uid())
    or (private.is_connected(b) and not private.is_blocked(b))
  )
$$;

-- Profile, bars, schedule: the above, or any signed-in user when the schedule
-- is public — unless that user is blocked.
create or replace function private.can_view_schedule(b uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select private.can_view_bartender(b)
    or (
      (select auth.uid()) is not null
      and exists (select 1 from public.bartenders where id = b and schedule_visibility = 'public')
      and not private.is_blocked(b)
    )
$$;

-- Who may read a row in public.profiles (display names only).
create or replace function private.can_see_profile(p uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select p = (select auth.uid())
    or exists (select 1 from public.connections c
               where c.bartender_id = (select auth.uid()) and c.regular_id = p)
    or exists (select 1 from public.blocks bl
               where bl.bartender_id = (select auth.uid()) and bl.regular_id = p)
    or (exists (select 1 from public.bartenders b where b.id = p) and private.can_view_schedule(p))
$$;

create or replace function private.try_uuid(t text)
returns uuid
language sql immutable
set search_path = ''
as $$
  select case
    when t ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then t::uuid
  end
$$;

-- ===== Bar day =====
-- A "bar day" runs 5am → 5am local, so a code or "tonight" lasts a whole late shift.

create or replace function private.bar_day(tz text)
returns date
language sql stable
set search_path = ''
as $$
  select ((now() at time zone tz) - interval '5 hours')::date
$$;

create or replace function private.bar_day_end(tz text, d date)
returns timestamptz
language sql stable
set search_path = ''
as $$
  select ((d + 1) + time '05:00') at time zone tz
$$;

-- ===== Invite codes =====
-- Format WORD-WORD-NN, e.g. TIKI-MOON-42. Short, common words that are easy to
-- say and spell; no homophones (sea/see), no US/UK spelling splits (color/colour).

create table private.code_words (word text primary key check (word ~ '^[A-Z]{3,6}$'));

insert into private.code_words (word)
select distinct unnest(string_to_array(btrim(regexp_replace(upper($words$
ACORN ALE ALLEY AMBER ANCHOR ANT APPLE AQUA ARCADE ARROW ATLAS ATTIC
BACON BADGE BADGER BAGEL BAKERY BANJO BARN BARREL BASIL BASKET BAT BEACH BEACON
BEAVER BELT BENCH BIKE BINGO BIRCH BISON BLACK BLOOM BOAT BOLD BOOK BOOT BOX
BRAVE BREAD BRICK BRIDGE BRIGHT BRONZE BROOK BRUSH BUBBLE BUCKET BUN BUTTON
CABIN CACTUS CAFE CAKE CALM CAMEL CAMERA CANDLE CANDY CANOE CANVAS CANYON CAP
CARD CARGO CART CASTLE CAT CAVE CEDAR CHAIR CHALK CHAPEL CHARM CHESS CIDER
CIRCLE CIRCUS CITY CLAM CLEVER CLIFF CLOCK CLOUD CLOVER COBRA COCOA COIN COMB
COMET COPPER CORAL CORK CORN COUCH COW CRAB CRANE CREAM CRISP CROW CROWN CUB
CUP CURRY DAISY DANCE DANDY DARTS DAWN DESK DICE DINER DISCO DOCK DOG DOODLE
DRAGON DRUM DUCK DUNE DUSK EAGER EAGLE EARTH ECHO EEL EGG ELK EMBER EMU EPIC
FANCY FARM FENCE FERN FIDDLE FIELD FIG FINCH FIRE FIZZY FLAG FLAME FLUTE FOG
FOREST FORK FOX FRESH FROG FROST FUDGE FUNNY FUZZY GADGET GALAXY GARDEN GECKO
GEM GENTLE GIANT GIN GLEN GLOVE GLOW GOAT GOLD GOLDEN GOOSE GRAND GRAPE GRAVY
GREEN GROVE GUITAR GUMBO HAMMER HANDY HAPPY HARP HAT HAWK HELMET HEN HERO HILL
HIPPO HONEY HOOK HORN HORSE HOTEL ICE IGLOO ISLAND IVORY IVY JACKET JADE JAM
JAR JAZZ JELLY JEWEL JINGLE JOKER JOLLY JUICY JUMBO JUNGLE KARMA KAYAK KEG
KETTLE KIND KING KITE KITTEN KIWI KOALA LADDER LAGER LAKE LAMB LAMP LASER LEAF
LEGEND LEMON LILAC LILY LIME LION LIVELY LLAMA LOCK LODGE LOTUS LUCKY LUNAR
MAGIC MAGNET MAMBO MANGO MAP MAPLE MARBLE MARKET MARS MASK MEADOW MELLOW MELON
MESA METRO MIGHTY MILL MINT MIRROR MITTEN MOCHA MOJO MOON MOOSE MOSS MOTEL MOTH
MOUSE MUG MULE NACHO NEEDLE NEON NIFTY NINJA NOBLE NOODLE NUGGET OAK OASIS
OCEAN OLIVE OMEGA ONION OPAL ORANGE ORBIT OTTER OWL PADDLE PALACE PALM PAN
PANDA PARK PARTY PASTA PEACH PEAK PEARL PEBBLE PECAN PENCIL PEPPER PIANO PICKLE
PIE PIG PILLOW PILOT PINE PINK PINT PIPE PIRATE PIXEL PIZZA PLANET PLATE PLAZA
PLUCKY PLUM POCKET POLKA POND PONY POOL POPPY PORCH POT PRINCE PRISM PROUD
PUFFIN PUPPY PURPLE PUZZLE QUAIL QUEEN QUICK QUIET QUILT RABBIT RADAR RADIO
RAFT RANCH RAPID RAVEN RIBBON RICE RIDDLE RING RIVER ROBIN ROBOT ROCK ROCKET
ROCKY ROPE ROSY ROVER ROYAL RUBY RULER RUM RUST RUSTY SADDLE SAFARI SAGA SALAD
SALOON SALSA SALT SAND SCARF SCOUT SEAL SHADOW SHARK SHEEP SHELL SHIELD SHINY
SHIP SHORE SHOVEL SIGNAL SILLY SILVER SKATE SKY SLED SLOTH SMART SNAIL SNAPPY
SNOW SOCK SODA SOFA SONIC SOUP SPACE SPARK SPICE SPICY SPIRAL SPOON SPRING
SPROUT SQUID STAR STONE STOOL STORK STORM STOUT STREET STUDIO STURDY SUGAR
SUMMIT SUNNY SUPER SWAN SWEET SWIFT SWING TABLE TACO TANGO TAP TAVERN TEA TEAL
TEMPO TENT TICKET TIDE TIDY TIGER TIKI TINY TOAD TOAST TOASTY TOFFEE TOKEN
TOPAZ TORCH TOWEL TOWER TOWN TRAIL TRAIN TREE TROPHY TROUT TRUCK TULIP TUNA
TUNDRA TURBO TURKEY TWIST VALLEY VASE VELVET VIKING VILLA VIOLIN VOYAGE WAGON
WALLET WALNUT WARM WHALE WHEEL WHITE WIDGET WILD WILLOW WINDOW WISE WITTY WIZARD
WOLF YAK YELLOW ZEBRA ZESTY ZIGZAG ZIPPER ZONE ZOOM
$words$), '\s+', ' ', 'g')), ' ')) as w
on conflict do nothing;

create or replace function private.normalize_code(t text)
returns text
language sql immutable
set search_path = ''
as $$
  select regexp_replace(upper(coalesce(t, '')), '[^A-Z0-9]', '', 'g')
$$;

-- New sayable code that is not currently active for anyone.
-- Caller must hold the daily-code advisory lock.
create or replace function private.new_daily_code()
returns text
language plpgsql volatile
set search_path = ''
as $$
declare
  words text[] := array(select word from private.code_words order by word);
  n int := cardinality(words);
  w1 text; w2 text; candidate text;
begin
  loop
    w1 := words[private.random_int(n) + 1];
    w2 := words[private.random_int(n) + 1];
    continue when w1 = w2;
    candidate := w1 || '-' || w2 || '-' || (10 + private.random_int(90))::text;
    exit when not exists (
      select 1 from public.invites
      where kind = 'daily'
        and code_norm = private.normalize_code(candidate)
        and expires_at > now() - interval '1 day'
    );
  end loop;
  return candidate;
end
$$;
