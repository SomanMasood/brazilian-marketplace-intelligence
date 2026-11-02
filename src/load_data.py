
from pathlib import Path

from .db_connection import get_connection


BASE_DIR = Path(__file__).resolve().parent.parent
DATA_DIR = BASE_DIR / "data" / "processed"


TABLES = [
    ("customers", "customers.csv"),
    ("products", "products.csv"),
    ("sellers", "sellers.csv"),
    ("category_translation", "category_translation.csv"),
    ("orders", "orders.csv"),
    ("order_items", "order_items.csv"),
    ("payments", "payments.csv"),
    ("reviews", "reviews.csv"),
    ("geolocation", "geolocation.csv"),
]


def load_table(cursor, table_name, file_name):
    file_path = DATA_DIR / file_name

    with open(file_path, "r", encoding="utf-8") as file:
        with cursor.copy(
            f"""
            COPY {table_name}
            FROM STDIN
            WITH (FORMAT csv, HEADER true)
            """
        ) as copy:
            while data := file.read(1024 * 1024):
                copy.write(data)

    cursor.execute(f"SELECT COUNT(*) FROM {table_name}")
    row_count = cursor.fetchone()[0]

    print(f"{table_name}: {row_count:,} rows")


def main():
    try:
        with get_connection() as connection:
            with connection.cursor() as cursor:
                for table_name, file_name in TABLES:
                    load_table(cursor, table_name, file_name)

            connection.commit()

        print("\nAll tables loaded successfully.")

    except Exception as error:
        print("\nLoad failed. Transaction rolled back.")
        print(f"Error: {error}")


if __name__ == "__main__":
    main()
