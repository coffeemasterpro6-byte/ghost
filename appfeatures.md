GHOST GAMING

Professional Flutter + Supabase Gaming Lounge Management System

You are the lead Flutter architect, senior Dart engineer, Supabase/PostgreSQL engineer, UI/UX implementation engineer, and QA engineer responsible for building the complete production-ready application Ghost Gaming.

Your job is NOT to create a prototype.

Your job is to build a real, scalable, synchronized Gaming Lounge Management System in Flutter with Supabase.

The application must be written in French.

All user-facing labels, buttons, messages, notifications, errors, forms, statuses, dialogs, invoices and dashboards must be in French.

Code identifiers may remain in English if that produces a cleaner technical architecture, but the visible application language is French.

---

0. NON-NEGOTIABLE RULES

Before writing code:

1. Inspect the existing project.
2. Inspect every provided HTML/CSS/asset/design file.
3. Understand the existing screen structure.
4. Do not throw away the existing design.
5. Do not replace the provided UI with generic Flutter UI.
6. Rebuild the provided design natively in Flutter.
7. Preserve the visual hierarchy, spacing, typography, cards, navigation, colors, icons, states, animations and responsive behavior.
8. If the HTML contains interactions, reproduce their behavior in Flutter.
9. Do not use WebView as a shortcut for the application UI.
10. The final application must be real Flutter widgets.
11. Do not hard-code business data into UI widgets.
12. Do not place Supabase queries directly inside large UI widgets.
13. Do not create fake local data once Supabase integration starts.
14. Do not create isolated features that cannot communicate with the rest of the system.
15. Every feature must integrate with the central data model.
16. Never implement a second competing architecture later.
17. Never duplicate business logic in multiple screens.
18. Never solve a synchronization problem with arbitrary refresh buttons.
19. Realtime synchronization must be event/data driven.
20. Never expose Supabase service-role credentials inside the Flutter application.

---

1. PRODUCT IDENTITY

Application name:

Ghost Gaming

The system is designed for Gaming Lounges / Gaming Cafés.

It manages:

- Gaming Posts
- PlayStation / Xbox / PC / VR or other stations
- Football games
- Match-based games
- Time-based games
- Sessions
- Customers
- Orders
- POS
- Products
- Inventory
- Payments
- Credit
- Wallet
- Reservations
- Notifications
- Employees
- Owner dashboard
- Reports
- Shifts
- Loyalty
- Memberships
- Packages
- Promotions
- Audit logs
- Realtime synchronization

---

2. VERY IMPORTANT CONCEPT

The core of the application is NOT the Post.

The real business hierarchy is:

Customer
↓
Session
↓
Post
↓
Game
↓
Time / Matches
↓
Orders
↓
Live Bill
↓
Payment
↓
Invoice

A Post represents the physical station.

A Session represents the customer's active gaming activity.

Orders may either be:

- standalone POS orders
- attached to an active Session

This distinction is mandatory.

---

3. APPLICATION ROLES

Implement role-based access control.

Roles:

Owner

Full access.

Manager

Configurable management access.

Employee

Operational access.

Customer

Customer application access.

Never rely only on Flutter-side role checks.

Authorization must also be enforced at Supabase/PostgreSQL RLS level.

---

4. OWNER APPLICATION

Owner features:

- Dashboard
- Posts
- Games
- Products
- Inventory
- Customers
- Sessions
- Orders
- Payments
- Credit
- Wallet
- Employees
- Reservations
- Notifications
- Reports
- Shifts
- Promotions
- Memberships
- Packages
- Loyalty
- Settings
- Audit Log

---

5. POST SYSTEM

Initial number:

12 Posts

But the number must be dynamic.

Owner can:

- Add Post
- Edit Post
- Disable Post
- Enable Post
- Rename Post
- Configure Post
- Assign supported games
- Set station type
- Set pricing rules

Post-game compatibility is stored in `post_games`. An empty mapping means that the post supports every game in the venue. An optional per-post/per-game price override is stored separately; otherwise the game catalog price is used. Match/time charge RPCs apply the effective post price and store the charged price in the session event. Starting or transferring a session is validated on the server.

Example:

POST 01
POST 02
...
POST 12

Later:

POST 13
POST 14
etc.

Do not hard-code 12 into business logic.

---

6. POST STATES

Use an explicit state machine.

Possible states:

available
reserved
starting
playing
paused
waiting_payment
maintenance
offline

Do not scatter arbitrary booleans such as:

isPlaying
isPaused
isReserved
isAvailable

when these can contradict each other.

Use a controlled state model.

---

7. POST WIDGET

The Post card must expose the most important information immediately.

Example:

POST 05

PLAYING

Mohamed
eFootball

MATCHES: 3
ELAPSED: 01:12:30

Games       300 DA
Products    400 DA

TOTAL       700 DA

Actions:

- + Match
- + Time
- Add Product
- Pause
- Resume
- Transfer
- View Session
- Payment
- Credit
- End Session

The exact visual implementation must follow the provided HTML design.

---

8. GAME MANAGEMENT

Owner has a dedicated Game Management screen.

Owner can:

- Create game
- Edit game
- Delete/deactivate game
- Upload game image
- Change game image
- Set game category
- Set pricing
- Set game mode
- Set match duration
- Set whether game is match-based
- Set whether game is time-based
- Enable/disable game

Example:

eFootball
Image
100 DA / Match

or:

Gaming PC
Image
50 DA / 15 minutes

---

9. AUTOMATIC FOOTBALL GAME DETECTION

THIS IS A CORE BUSINESS REQUIREMENT.

The application must automatically recognize football games that use the MATCH system.

Do NOT depend on manually configuring every game if its name can be recognized safely.

Create a centralized:

GameClassificationService

The service determines whether a game is:

football_match
time_based
other

The initial football aliases must include variations such as:

eFootball
eFootball 2026
eFootball 2025
eFootball PES
PES
PES 2021
EA FC
FC 26
FC 25
FIFA
FIFA 23
FIFA 24
FIFA 25
FIFA 26

The matching algorithm must be:

- case-insensitive
- accent-insensitive
- whitespace-normalized
- tolerant of common naming variations

Do not make the system depend on one exact string.

However:

IMPORTANT

Automatic detection must NOT prevent Owner override.

Owner must always be able to explicitly configure:

MATCH_BASED
TIME_BASED
CUSTOM

The explicit Owner configuration takes precedence over automatic classification.

---

10. FOOTBALL MATCH TIME LOGIC

For recognized football match games:

The actual gaming station timer must account for the game's internal match duration.

Define:

effective_match_minutes

For eFootball:

effective_time = match_game_time × 1.7

For the other configured football games:

effective_time = match_game_time × 1.5

Do not hard-code these formulas inside widgets.

Create:

GameTimingPolicy

with configurable multipliers.

Example:

eFootball
Game Match Time = 10 minutes
Multiplier = 1.7
Effective Station Time = 17 minutes

Another football game:

Game Match Time = 10 minutes
Multiplier = 1.5
Effective Station Time = 15 minutes

---

11. WHY THE MULTIPLIER EXISTS

The system is not simply counting the game's internal match timer.

It calculates the estimated real station occupation time.

The Post must therefore show:

MATCH 2 / 3

Match duration:
10 min

Estimated station time:
17 min

Remaining:
08:34

The remaining time must be calculated from actual timestamps, NOT by decrementing a Dart variable every second and treating that variable as the source of truth.

---

12. SOURCE OF TRUTH FOR TIMERS

NEVER store:

remainingSeconds

as the authoritative session state.

Store timestamps:

started_at
paused_at
ended_at
total_paused_seconds
planned_duration_seconds

The Flutter UI calculates:

remaining = plannedDuration - elapsed

using the current time.

This prevents timer drift.

When the application is backgrounded or rebuilt, the timer must recover correctly.

When another phone opens the same session, it must calculate the same remaining time.

---

13. MATCH SESSION MODEL

A football session can contain:

Match 1
Match 2
Match 3
...

Every added match increases:

match_count

and the total planned/effective session duration.

Example:

Match duration = 10 min
Multiplier = 1.7

1 match = 17 min
2 matches = 34 min
3 matches = 51 min

Do not simply add an arbitrary countdown value.

The domain layer must calculate it.

---

14. NON-FOOTBALL GAMES

Other games can use true time-based sessions.

Example:

Start: 16:00
Duration: 60 minutes

The Post displays:

01:00:00

remaining.

Pricing can be:

- per minute
- per 15 minutes
- per 30 minutes
- per hour
- custom pricing rule

The pricing engine must be configurable.

---

15. PRICING ENGINE

Do not hard-code prices in UI.

Create:

PricingService

It must support:

per_match
per_minute
per_15_minutes
per_30_minutes
per_hour
fixed_price
package
promotion
membership_discount

Pricing calculations belong to the domain layer.

---

16. CUSTOMER APPLICATION

The Customer Home must automatically display content managed by Owner.

Owner creates:

Game

Customer automatically sees it.

Owner changes:

Game image
Game name
Game price
Availability

Customer receives the updated information through Supabase.

No hard-coded game catalog.

---

17. CUSTOMER HOME

Customer Home contains:

- Games
- Products
- Current Session
- Current Post
- Live Bill
- Orders
- Requests
- Wallet
- Credit
- Reservations
- Membership
- Loyalty
- Notifications

UI must follow the provided design.

---

18. POST ↔ CUSTOMER LINKING

Support QR-based Post linking.

Each Post can have:

post_qr_token

Customer scans QR.

The application associates:

Customer
+
Post

and can request/start a Session according to permissions.

Never trust the QR token alone for authorization.

Validate it through backend rules.

---

19. SESSION CREATION

When a Session starts:

Create a real database record.

Minimum information:

id
customer_id
post_id
game_id
started_at
ended_at
paused_at
planned_duration_seconds
match_count
status
created_by

The Session is the central record.

---

20. MATCH REQUEST

Customer can request:

+ Match

Create a real request:

SessionRequest

Status:

pending
approved
rejected
cancelled
completed

Employee/Manager sees:

POST 05
Mohamed
Requests +1 Match

Accepting the request must trigger a transactional business operation.

It must:

1. Validate Session is still active.
2. Validate the Post.
3. Validate pricing.
4. Increment match count.
5. Update planned duration.
6. Create an audit event.
7. Update the live bill.
8. Notify relevant clients.
9. Return the new authoritative state.

Do NOT perform these as unrelated client writes.

---

21. TIME REQUEST

Customer can request:

+10 min
+30 min
+60 min

Same workflow:

pending
approved
rejected
cancelled
completed

The server-side business operation must update the Session atomically.

---

22. PRODUCTS FROM POST

From the current Post/Session:

Customer can order:

Coca-Cola
Pepsi
Water
Coffee
Chocolate
Chips
Snacks
...

Options:

Add to Session

or:

Pay Now

This distinction is mandatory.

---

23. STANDALONE ORDER

Example:

Customer buys Coca-Cola.

Customer chooses:

Pay Now

The system creates:

Order
Payment
Invoice

without creating or modifying a gaming Session.

---

24. SESSION ORDER

If customer chooses:

Add to Session

the order item becomes associated with:

session_id

and appears in the Live Bill.

---

25. PRE-SESSION ORDER

Customer can purchase a product before playing.

Example:

Coca-Cola
Paid
No Session

Later the customer starts:

POST 05
eFootball

The system can offer:

Add previous order to current Session

Do not automatically attach paid orders unless the business rule explicitly says so.

---

26. INVENTORY

Product table:

id
name
image_url
category_id
sale_price
cost_price
stock_quantity
minimum_stock
is_available
created_at
updated_at

Every stock mutation must be traceable.

Create:

inventory_movements

Examples:

sale
restock
return
damage
manual_adjustment
correction

Never simply update stock without recording why.

---

27. ATOMIC INVENTORY OPERATIONS

When selling:

Coca-Cola ×2

the backend must ensure:

stock >= 2

before reducing it.

Avoid race conditions where two phones sell the last item simultaneously.

Prefer a server-side/Postgres transactional operation or RPC for critical mutations.

The Flutter client should request the operation rather than manually performing multiple dependent updates.

---

28. LIVE BILL

A Session Bill is derived from:

Gaming charges
+
Match charges
+
Time charges
+
Session orders
-
Discounts
-
Payments
+
Applicable taxes/fees if configured

Do not store many duplicated totals unless necessary.

If cached totals are stored, define exactly when and how they are recalculated.

---

29. PAYMENTS

Support:

cash
card
wallet
partial_payment
credit
split_payment

Example:

Total = 1000 DA

Cash = 500
Wallet = 300
Credit = 200

The system must guarantee:

sum(payments) + credit = total

when the invoice is closed.

---

30. WALLET

Wallet is NOT Credit.

Wallet:

Money owned by customer and prepaid.

Credit:

Money owed by customer.

Keep them separate in the database and UI.

---

31. CREDIT

Customer may have:

credit_balance

Every credit operation must have a ledger entry.

Never modify:

credit_balance

without creating a corresponding ledger record.

---

32. CUSTOMER LEDGER

Create a financial ledger.

Every operation:

charge
payment
credit
wallet_topup
wallet_usage
refund
adjustment

must be traceable.

---

33. NOTIFICATION SYSTEM

Notifications must be persisted.

Example:

POST 05 requests +1 Match

Create:

notification

with:

recipient_id
type
title
body
reference_type
reference_id
is_read
created_at

Support:

- in-app notifications
- realtime notifications
- push notifications later

Do not rely only on a local SnackBar.

---

34. REALTIME SUPABASE ARCHITECTURE

Supabase Realtime is mandatory.

Use it for:

- Posts
- Sessions
- Orders
- Order requests
- Products
- Inventory updates
- Notifications
- Reservations
- Payments where appropriate
- Customer-facing live state

Supabase supports listening to Postgres database changes through Realtime channels.

Realtime must not become a random subscription in every widget.

Create centralized realtime services/repositories.

---

35. REALTIME RULE

Example:

Employee phone:

POST 05 → Match 2

writes to Supabase.

Owner phone receives:

Realtime event

Repository updates state.

ViewModel updates state.

Flutter rebuilds only the required UI.

Customer receives the same authoritative state.

Architecture:

Supabase
↓
Realtime Service
↓
Repository
↓
ViewModel / State
↓
UI

NOT:

Widget
↓
Supabase
↓
setState everywhere

---

36. REALTIME CHANNELS

Use a clear channel strategy.

Examples:

venue:{venueId}:posts
venue:{venueId}:sessions
venue:{venueId}:orders
venue:{venueId}:notifications
session:{sessionId}
post:{postId}
customer:{customerId}

Use private channels where authorization is required.

Supabase provides Realtime authorization through RLS policies on "realtime.messages", allowing control over who can subscribe/publish to channels.

Do not create an excessive number of subscriptions without lifecycle management.

---

37. REALTIME SUBSCRIPTION LIFECYCLE

Every subscription must:

- be created intentionally
- be disposed
- avoid duplicates
- reconnect safely
- handle authentication changes
- handle app lifecycle

Do not create subscriptions inside "build()".

---

38. RLS SECURITY

Every business table must have RLS enabled.

Never rely on Flutter:

if role == owner

as the security mechanism.

Flutter checks are for UX.

Supabase/Postgres RLS is the security boundary.

Supabase's current Flutter guidance explicitly requires appropriate Data API permissions and RLS policies for tables accessed by the client.

---

39. MULTI-TENANCY

The application must be designed for multiple Gaming Lounges.

Every business record must belong to:

venue_id

Examples:

venues
posts
games
products
sessions
orders
customers
employees
notifications

Never allow Venue A to access Venue B data.

RLS must enforce this.

---

40. DATABASE DESIGN

At minimum consider these tables:

venues
profiles
venue_members
roles
posts
games
game_categories
game_pricing
customers
sessions
session_matches
session_requests
products
product_categories
orders
order_items
inventory_movements
payments
invoices
invoice_items
credit_accounts
credit_ledger
wallets
wallet_transactions
reservations
notifications
notification_preferences
shifts
shift_transactions
promotions
memberships
membership_plans
loyalty_accounts
loyalty_transactions
audit_logs

Do not blindly create all tables before validating relationships.

Create migrations in logical phases.

---

41. DATABASE CONSTRAINTS

Use PostgreSQL constraints wherever possible.

Examples:

- foreign keys
- unique constraints
- check constraints
- not-null constraints
- indexes

Business invariants should not exist only in Dart.

---

42. SERVER-SIDE BUSINESS OPERATIONS

Critical operations should be atomic.

Examples:

start_session
approve_match_request
approve_time_request
add_session_product
create_payment
close_session
transfer_session
process_refund
apply_credit
consume_wallet
sell_product

Use PostgreSQL functions/RPC where atomicity is important.

Flutter calls the business operation.

The database performs the transaction.

This prevents two phones from independently corrupting the same Session.

---

43. EXAMPLE: APPROVE MATCH

Conceptually:

approve_match_request(request_id)

Backend:

1. Lock/validate Session.
2. Verify request is pending.
3. Verify Session active.
4. Determine game policy.
5. Calculate additional duration.
6. Increment match count.
7. Update session.
8. Mark request approved/completed.
9. Create audit log.
10. Create notification.
11. Return authoritative session state.

This must be one business transaction.

---

44. SESSION CONCURRENCY

Handle:

Employee A → +Match
Employee B → End Session
Customer → +Match

at nearly the same time.

The system must have a defined concurrency strategy.

Never assume devices act sequentially.

---

45. OFFLINE STRATEGY

Do not pretend Supabase Realtime means offline synchronization is automatically solved.

Design explicitly for:

online
temporarily offline
reconnecting
synced
sync_error

Critical financial operations should not be blindly duplicated offline.

If offline support is implemented, use:

- local persistence
- operation IDs
- idempotency keys
- sync queue
- conflict policy

For example:

operation_id = UUID

If the same operation is retried, backend must not execute it twice.

Current implementation:

- RPCs protected by the backend idempotency key `p_op` are persisted in an encrypted Hive queue; retries retain the original operation ID.
- Operations are sent serially for the account that created them. A server rejection blocks later operations until the rejected operation is retried or explicitly discarded after review.
- Direct table writes and RPCs without `p_op` remain online-only. Network connectivity is only a hint; the RPC response is the confirmation.

---

46. STATE MANAGEMENT

Use a predictable state-management architecture.

Recommended structure:

View
ViewModel
Repository
Service

with domain/use-case logic where complexity requires it.

This follows Flutter's current architecture guidance around Views, ViewModels, Repositories and Services.

Do not allow widgets to become business-logic containers.

---

47. NAVIGATION

Use:

go_router

for application navigation.

Define route guards for:

authenticated
owner
manager
employee
customer

Flutter's architecture recommendations currently list "go_router" as the preferred navigation solution for most applications.

---

48. PROJECT STRUCTURE

Use feature-oriented architecture.

Example:

lib/
app/
app.dart
router/
theme/

core/
constants/
errors/
extensions/
utils/
result/
network/

features/
auth/
data/
domain/
presentation/

    dashboard/
      data/
      domain/
      presentation/

    posts/
      data/
      domain/
      presentation/

    sessions/
      data/
      domain/
      presentation/

    games/
      data/
      domain/
      presentation/

    products/
      data/
      domain/
      presentation/

    inventory/
      data/
      domain/
      presentation/

    orders/
      data/
      domain/
      presentation/

    payments/
      data/
      domain/
      presentation/

    customers/
      data/
      domain/
      presentation/

    credit/
      data/
      domain/
      presentation/

    wallet/
      data/
      domain/
      presentation/

    notifications/
      data/
      domain/
      presentation/

    reservations/
      data/
      domain/
      presentation/

    reports/
      data/
      domain/
      presentation/

---

49. REPOSITORIES

Examples:

PostRepository
SessionRepository
GameRepository
ProductRepository
InventoryRepository
OrderRepository
PaymentRepository
CustomerRepository
NotificationRepository
ReservationRepository

Repositories are the source of truth for application data.

Flutter's architecture guidance recommends repositories as the source of truth and abstract repositories for testability and environment-specific implementations.

---

50. SUPABASE SERVICES

Create dedicated services such as:

SupabaseAuthService
SupabaseRealtimeService
SupabaseStorageService
SupabaseDatabaseService

Do not duplicate Supabase client initialization across features.

---

51. STORAGE

Game images and product images must use Supabase Storage or another explicitly configured storage provider.

Database stores:

image_url

not binary image data.

Use image caching in Flutter.

---

52. DESIGN IMPLEMENTATION

The supplied HTML design is the visual source of truth.

The Agent must:

1. Inspect HTML.
2. Inspect CSS.
3. Inspect assets.
4. Identify reusable components.
5. Identify design tokens.
6. Convert them into Flutter Theme/Data structures.
7. Rebuild screens with Flutter widgets.

Create reusable components:

AppButton
AppCard
AppTextField
AppDialog
StatusBadge
PostCard
GameCard
ProductCard
OrderCard
InvoiceCard
StatCard
BottomNavigation
SideNavigation

Do not duplicate the same visual component in multiple files.

---

53. CLASSIC MODERN UI IMPLEMENTATION

The UI should feel:

- premium
- modern
- fast
- clean
- professional
- gaming-oriented
- responsive
- information-dense without being confusing

Use:

- responsive layouts
- adaptive spacing
- reusable components
- animations only where meaningful
- loading states
- empty states
- error states
- skeletons where appropriate
- optimistic UI only where safe

Do not blindly copy HTML pixel-by-pixel if it produces broken Flutter layouts.

Preserve the design intent while adapting it to Flutter's layout system.

---

54. RESPONSIVE DESIGN

The application may run on:

- Android phones
- tablets
- potentially desktop/web later

Do not assume:

width = 360

Use:

LayoutBuilder
MediaQuery
Flexible
Expanded
Wrap
Sliver
responsive breakpoints

where appropriate.

---

55. FRENCH LOCALIZATION

All UI text must be French.

Examples:

Tableau de bord
Post
Session
Joueur
Match
Temps restant
Ajouter un match
Ajouter du temps
Ajouter un produit
Payer maintenant
Ajouter à la session
En attente
Accepté
Refusé
Terminé
Disponible
En cours
En pause
Paiement en attente
Crédit
Portefeuille
Stock
Produits
Notifications
Réservations
Rapports
Employés
Paramètres

Do not mix Arabic/French/English in the UI.

Technical identifiers may remain English.

---

56. TIME ZONE

The application is intended for Algeria.

Store timestamps consistently in UTC in the backend where appropriate.

Convert to the venue timezone for display.

Do not manually add/subtract one hour throughout the code.

Centralize timezone handling.

---

57. DATE/TIME DISPLAY

Use French formatting.

Example:

03 octobre 2026
16:42

Use proper localization.

---

58. NOTIFICATION UX

Notifications should deep-link to the relevant entity.

Example:

User receives:

POST 05 demande un match supplémentaire

Tapping notification opens:

POST 05 / Session #501

not merely the notification page.

---

59. SEARCH

Global search should support:

customers
posts
sessions
orders
products
invoices
credit

Use debouncing for search fields.

Do not query Supabase on every keystroke without control.

---

60. AUDIT LOG

Log sensitive operations:

price_change
session_start
session_end
match_added
time_added
order_cancelled
payment_created
refund
credit_change
wallet_change
inventory_adjustment
role_change

Record:

actor_id
venue_id
action
entity_type
entity_id
metadata
created_at

---

61. ERROR HANDLING

Every network/database operation must have:

loading
success
empty
error
retry

Do not show raw Postgres/Supabase exceptions to users.

Convert technical errors into French user-friendly messages.

Log technical details separately.

---

62. TESTING

Do not consider a feature finished merely because the screen works.

Implement:

Unit tests

For:

- pricing
- game classification
- football multipliers
- remaining-time calculation
- match duration
- credit calculations
- wallet calculations
- invoice totals
- order states

Repository tests

For:

- CRUD
- realtime transformations
- error handling

Widget tests

For:

- Post card
- Session screen
- Order screen
- Payment UI
- Dashboard

Integration tests

At minimum:

Start Session
→ Add Match
→ Add Product
→ Payment
→ Close Session

and:

Customer device
↔ Employee device
↔ Owner device

Flutter recommends testing services/repositories/ViewModels separately and widget testing views.

---

63. CRITICAL TEST

The following scenario MUST work:

DEVICE A

Employee opens:

POST 05

Starts:

eFootball
Match 1

DEVICE B

Owner opens Dashboard.

Must see immediately:

POST 05
Playing
eFootball
Match 1

DEVICE A

Employee approves:

+ Match

DEVICE B

Owner must see:

Match 2

without manual refresh.

DEVICE C

Customer opens current session.

Must also see:

Match 2

This is a mandatory acceptance test.

---

64. SECOND REALTIME TEST

Device A:

Customer orders Coca-Cola ×2

Device B:

Employee sees pending order

Employee approves.

Device A:

Order = Ready

Inventory:

Coca-Cola stock -2

Session bill:

+ Coca-Cola ×2

Owner:

sees updated revenue/inventory

All without manual refresh.

---

65. THIRD REALTIME TEST

Owner changes:

FIFA
100 DA

to:

120 DA

Customer application must receive the new configuration.

No rebuilding the application.

No hard-coded value.

---

66. FOURTH TEST — FOOTBALL TIMER

Configure:

Game = eFootball
Match duration = 10 min
Multiplier = 1.7

Expected:

Effective duration = 17 min

After 5 minutes of real elapsed time:

Remaining ≈ 12 min

The timer must remain correct after:

- screen rebuild
- navigation
- app background
- reopening the session
- another device opening the session

---

67. FIFTH TEST — NON-FOOTBALL

Configure:

Game = Tekken
Duration = 60 min

Expected:

60 real minutes

No football multiplier.

---

68. DO NOT IMPLEMENT EVERYTHING AT ONCE

Build incrementally.

Recommended order:

Phase 1

Foundation:

- Flutter project
- Theme
- Routing
- Supabase
- Auth
- Database migrations
- RLS
- Base architecture

Phase 2

Owner:

- Dashboard
- Posts
- Games

Phase 3

Session Engine:

- Session
- Match
- Time
- Football detection
- Timing engine

Phase 4

Customer:

- Home
- Games
- Post linking
- Session view

Phase 5

POS:

- Products
- Orders
- Inventory
- Live Bill

Phase 6

Payments:

- Cash
- Wallet
- Credit
- Invoice

Phase 7

Realtime:

- Posts
- Sessions
- Orders
- Notifications

Phase 8

Advanced:

- Reservations
- Loyalty
- Membership
- Packages
- Promotions
- Shifts
- Reports

Phase 9

Hardening:

- Tests
- Security
- Concurrency
- Offline/reconnect
- Performance
- Error handling

---

69. AGENT WORKING METHOD

For every phase:

1. Inspect current project.
2. State what already exists.
3. Identify what must change.
4. Design database changes first if required.
5. Create migration.
6. Apply security/RLS.
7. Implement domain models.
8. Implement repository.
9. Implement service.
10. Implement ViewModel/state.
11. Implement UI using existing design.
12. Connect Realtime.
13. Test.
14. Fix errors.
15. Only then move to next feature.

Never generate 50 unrelated files at once.

Current implementation notes:

- A debounced global search is available to authenticated staff and customers. Results are limited by the active venue and database RLS; customer credit balances are shown only to roles allowed to manage credit.
- Core session and catalog changes use private venue broadcasts with repository-owned subscriptions. Some secondary screens still own subscriptions directly.
- Multi-device acceptance flows require a configured Supabase project and multiple authenticated clients; unit tests alone do not verify that deployment scenario.

---

70. IMPORTANT AGENT BEHAVIOR

If you encounter an architectural problem:

DO NOT hide it.

Explain:

Problem
Cause
Recommended solution
Files affected
Database affected
Migration required

Then implement the safest solution.

If a requirement is ambiguous, preserve the existing architecture and ask only when the ambiguity can materially change data integrity.

Do not make arbitrary architectural decisions that can corrupt existing data.

---

71. DEFINITION OF DONE

A feature is NOT complete until:

- UI exists.
- UI follows provided design.
- French localization exists.
- Database exists.
- RLS exists.
- Repository exists.
- Business logic exists.
- Realtime behavior exists where required.
- Loading state exists.
- Error state exists.
- Empty state exists.
- Tests exist for important logic.
- It works from at least two devices when the feature is realtime.
- No hard-coded production data exists.
- No service-role secret exists in Flutter.
- No duplicate business logic exists.

---

72. FINAL ARCHITECTURE

Target:

                    GHOST GAMING
                          │
        ┌─────────────────┼─────────────────┐
        │                 │                 │
     OWNER             EMPLOYEE          CUSTOMER
        │                 │                 │
        └─────────────────┼─────────────────┘
                          │
                    FLUTTER APP(S)
                          │
                 Presentation Layer
                          │
                    ViewModels
                          │
                    Domain Layer
                          │
                  Repositories
                          │
                    Data Services
                          │
                     SUPABASE
                          │
       ┌──────────────────┼──────────────────┐
       │                  │                  │
PostgreSQL           Auth              Storage
│
RLS
│
Transactions
│
Realtime

The system must remain modular enough that another developer can add a feature without rewriting the application.

---

73. MOST IMPORTANT PRINCIPLE

Build Ghost Gaming as a real software product, not as a collection of screens.

The UI is the visible layer.

The real product is:

Domain Model
+
Database
+
Security
+
Transactions
+
Realtime
+
State Management
+
UI/UX
+
Testing

Every screen must be connected to real application state.

Every important operation must have a defined business rule.

Every critical shared operation must be safe when multiple devices perform it simultaneously.

The provided HTML design controls the visual language.

Supabase controls the shared persistent data.

Flutter controls the application experience.

The domain layer controls the business rules.

PostgreSQL/RLS controls data integrity and authorization.

Realtime connects the devices.

The result must be a production-quality application named:

GHOST GAMING

Gaming Lounge Management System