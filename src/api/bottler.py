from fastapi import APIRouter, Depends
from enum import Enum
from pydantic import BaseModel
from src.api import auth
import sqlalchemy as sa
from src import database as db


router = APIRouter(
    prefix="/bottler",
    tags=["bottler"],
    dependencies=[Depends(auth.get_api_key)],
)

class PotionInventory(BaseModel):
    potion_type: list[int]
    quantity: int

@router.post("/deliver")
def post_deliver_bottles(potions_delivered: list[PotionInventory]):
    """ """
    print(potions_delivered)

    return "OK"


# Gets called 4 times a day
@router.post("/plan")
def get_bottle_plan():
    """
    Go from barrel to bottle.
    """

    # Each bottle has a quantity of what proportion of red, blue, and
    # green potion to add.
    # Expressed in integers from 1 to 100 that must sum up to 100.

    # Initial logic: bottle all barrels into red potions.

    with db.engine.begin() as con:
        ml_red = con.execute(sa.select(db.global_inventory.c.num_red_ml)).fetchone()[0]
        
        if(ml_red != 0):
            make_red = ml_red // 100
            result = con.execute(
                db.global_inventory.
                update().
                values(
                        {
                            "num_red_potion": db.global_inventory.c.num_red_potion + make_red,
                            "num_red_ml": ml_red - make_red * 100,
                            "gold": db.global_inventory.c.gold
                        }
                    )
                )

            return [
                    {
                        "potion_type": [100, 0, 0, 0],
                        "quantity": make_red,
                    }
                ]
        else:
            return [
                    {
                        "potion_type": [0, 0, 0, 0],
                        "quantity": 0,
                    }
                ]
