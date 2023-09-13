import os
import dotenv
import sqlalchemy as sa

def database_connection_url():
    dotenv.load_dotenv()

    return os.environ.get("POSTGRES_URI")

engine = sa.create_engine(database_connection_url(), pool_pre_ping=True)

# Create a metadata object for each table
metadata_obj = sa.MetaData()

# Load tables
global_inventory = sa.Table("global_inventory", metadata_obj, autoload_with=engine)
