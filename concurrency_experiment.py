import sqlite3
import threading
from pathlib import Path

DB = Path("concurrency_demo_small.db")
if DB.exists():
    DB.unlink()

def connect():
    c = sqlite3.connect(DB, timeout=10, isolation_level=None)
    c.execute("PRAGMA journal_mode=WAL")
    return c

# Small isolated test table
c = connect()
c.execute("CREATE TABLE account (id INTEGER PRIMARY KEY, balance INTEGER)")
c.execute("INSERT INTO account VALUES (1, 100)")
c.close()

def reset():
    c = connect()
    c.execute("UPDATE account SET balance=100 WHERE id=1")
    c.close()

def balance():
    c = connect()
    result = c.execute("SELECT balance FROM account WHERE id=1").fetchone()[0]
    c.close()
    return result

# ---------------------------------------------------------
# Part A: Lost update from stale application-level reads
# ---------------------------------------------------------
reset()
both_read = threading.Barrier(2)
events = []

def unsafe_worker(name):
    c = connect()
    old = c.execute("SELECT balance FROM account WHERE id=1").fetchone()[0]
    events.append(f"{name} reads balance={old}")
    both_read.wait()

    # Both calculate from the same stale value.
    new = old - 10
    c.execute("UPDATE account SET balance=? WHERE id=1", (new,))
    events.append(f"{name} writes balance={new}")
    c.close()

threads = [
    threading.Thread(target=unsafe_worker, args=("T1",)),
    threading.Thread(target=unsafe_worker, args=("T2",)),
]
for t in threads:
    t.start()
for t in threads:
    t.join()

print("\nPART A: UNSAFE READ-MODIFY-WRITE")
for event in events:
    print(event)
print("Expected balance if both deductions apply: 80")
print("Actual final balance:", balance())

# ---------------------------------------------------------
# Part B: Protect the entire read-modify-write transaction
# ---------------------------------------------------------
reset()
start_together = threading.Barrier(2)
events = []
errors = []

def safe_worker(name):
    c = connect()
    try:
        start_together.wait()
        c.execute("BEGIN IMMEDIATE")
        old = c.execute(
            "SELECT balance FROM account WHERE id=1"
        ).fetchone()[0]
        events.append(f"{name} reads balance={old}")
        new = old - 10
        c.execute("UPDATE account SET balance=? WHERE id=1", (new,))
        c.execute("COMMIT")
        events.append(f"{name} commits balance={new}")
    except Exception as e:
        errors.append(f"{name}: {type(e).__name__}: {e}")
        if c.in_transaction:
            c.execute("ROLLBACK")
    finally:
        c.close()

threads = [
    threading.Thread(target=safe_worker, args=("T1",)),
    threading.Thread(target=safe_worker, args=("T2",)),
]
for t in threads:
    t.start()
for t in threads:
    t.join()

print("\nPART B: BEGIN IMMEDIATE")
for event in events:
    print(event)
for error in errors:
    print("ERROR:", error)
print("Expected final balance: 80")
print("Actual final balance:", balance())

if not errors and balance() == 80:
    print("\nPASS: Both deductions applied under transaction locking.")
else:
    print("\nCHECK: Review the output before drawing a conclusion.")
