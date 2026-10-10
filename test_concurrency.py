import sqlite3

DB = "concurrency_test.db"

c1 = sqlite3.connect(DB, timeout=1)
c2 = sqlite3.connect(DB, timeout=1)

try:
    c1.execute("PRAGMA journal_mode")
    print("Connection 1: BEGIN IMMEDIATE")
    c1.execute("BEGIN IMMEDIATE")

    print("Connection 1: writer reservation acquired")
    print("Connection 2: attempting BEGIN IMMEDIATE")

    try:
        c2.execute("BEGIN IMMEDIATE")
        print("Connection 2: unexpectedly acquired writer reservation")
        c2.rollback()
    except sqlite3.OperationalError as e:
        print(f"Connection 2 result: {type(e).__name__}: {e}")

    c1.rollback()
    print("Connection 1: ROLLBACK complete")
finally:
    if c1.in_transaction:
        c1.rollback()
    if c2.in_transaction:
        c2.rollback()
    c1.close()
    c2.close()
