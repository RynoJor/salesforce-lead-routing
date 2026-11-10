"""Write data/leads.json: 50 synthetic inbound leads for `sf data import tree`.

Deterministic (fixed seed). Every email is on example.com. The last few records are planted
cases that exercise the duplicate check and validation, the same cases as the n8n replay:

    same email, different case       -> Existing owner (duplicate_contact)
    company + legal suffix            -> Existing owner (known_account)
    company typo + same email domain  -> Existing owner (known_account)
    look-alike company, nothing else  -> new business, normal round robin
    no email                          -> Lead Triage queue
    LATAM / blank region              -> Default rule (unknown_region / missing_region)

Run from the repo root:  python scripts/make_seed.py
"""

import json
import random
from pathlib import Path

random.seed(42)

FIRST = ["Avery", "Jordan", "Priya", "Nora", "Sam", "Lena", "Tomas", "Mei", "Kofi", "Ines", "Ravi",
         "Hana", "Owen", "Zara", "Luca", "Amara", "Felix", "Yuki", "Diego", "Freya", "Omar", "Elin",
         "Mateo", "Ayla", "Theo"]
LAST = ["Example", "Lee", "Nair", "Galloway", "Ortiz", "Fischer", "Novak", "Tanaka", "Mensah",
        "Duarte", "Iyer", "Sato", "Brennan", "Haddad", "Romano", "Okafor", "Lindqvist", "Mori",
        "Vargas", "Holm", "Rahman", "Berg", "Silva", "Kaya", "Moreau"]
# (company, standard Lead.Industry)
COMPANIES = [
    ("Quillbrook Pilates Studio", "Recreation"), ("Maplewood Physio", "Healthcare"),
    ("Sunridge Coffee", "Food & Beverage"), ("Larkwell Bakery", "Food & Beverage"),
    ("Riverlight Clinic", "Healthcare"), ("Harborview Dental", "Healthcare"),
    ("Brightpath Tutoring", "Education"), ("Copperleaf Consulting", "Consulting"),
    ("Northwind Outfitters", "Retail"), ("Bluefern Yoga", "Recreation"),
    ("Ironbark Fitness", "Recreation"), ("Stillwater Advisors", "Consulting"),
    ("Kestrel Realty", "Other"), ("Amberline Salon", "Other"), ("Granite Peak Motors", "Other"),
    ("Willowmere Inn", "Hospitality"), ("Pinecrest Pharmacy", "Healthcare"),
    ("Marigold Catering", "Food & Beverage"), ("Saltmarsh Design", "Consulting"),
    ("Juniper Wellness", "Healthcare"), ("Fernhill Academy", "Education"),
    ("Redwood Legal", "Consulting"), ("Lanternfish Market", "Retail"),
    ("Oakhaven Chiropractic", "Healthcare"), ("Silvermoss Spa", "Other"),
    ("Tidewater Athletics", "Recreation"), ("Cobalt Ridge Accounting", "Consulting"),
    ("Hollowbrook Goods", "Retail"), ("Starling Physio", "Healthcare"),
    ("Driftwood Guesthouse", "Hospitality"), ("Emberstone Gym", "Recreation"),
    ("Clearwater Learning", "Education"), ("Rosewood Boutique", "Retail"),
    ("Thornfield Health", "Healthcare"), ("Mistral Kitchen", "Food & Beverage"),
    ("Brambleway Homes", "Other"), ("Glasswing Studio", "Recreation"),
    ("Coralbay Nails", "Other"), ("Highmoor Tires", "Other"), ("Wrenfield Clinic", "Healthcare"),
    ("Ashgrove Deli", "Food & Beverage"), ("Moonpetal Wellness", "Healthcare"),
]
REGIONS = ["North America"] * 9 + ["EMEA"] * 7 + ["APAC"] * 4
SOURCES = ["Demo Request", "Free Trial", "Website Form", "Content Download"]
SIZES = [4, 8, 15, 30, 45, 60, 120, 180]


def slug(company):
    return "".join(ch for ch in company.lower() if ch.isalnum())


def lead(n, first, last, company, industry, email, region, source, size):
    rec = {
        "attributes": {"type": "Lead", "referenceId": f"SeedLead{n:02d}"},
        "FirstName": first,
        "LastName": last,
        "Company": company,
        "Industry": industry,
        "NumberOfEmployees": size,
        "Inbound_Source__c": source,
        "Status": "Open - Not Contacted",
        "Description": "Synthetic portfolio lead (not a real person or business).",
    }
    if email:
        rec["Email"] = email
    if region:
        rec["Region__c"] = region
    return rec


records = []
for i in range(42):
    company, industry = COMPANIES[i]
    first, last = FIRST[i % len(FIRST)], LAST[(i * 7) % len(LAST)]
    records.append(lead(
        i + 1, first, last, company, industry,
        f"{first.lower()}@{slug(company)}.example.com",
        random.choice(REGIONS), random.choice(SOURCES), random.choice(SIZES)))

planted = [
    # same person again, email in a different case, from another region
    ("Nora", "Galloway", "Larkwell Bakery", "Food & Beverage", "Nora@LarkwellBakery.example.com".replace("LarkwellBakery", "Larkwellbakery"), "North America", "Free Trial", 15),
    # known account: same company with a legal suffix, different contact
    ("Ben", "Achebe", "Brightpath Tutoring Ltd", "Education", "ben@brightpathtutoring-mail.example.com", "APAC", "Website Form", 30),
    # typo in the company name, same email domain as the original
    ("Jo", "Pereira", "Riverlight Clinik", "Healthcare", "jo@riverlightclinic.example.com", "EMEA", "Demo Request", 45),
    # look-alike name, nothing else in common: a different business
    ("Kim", "Larsen", "Silverlight Clinic", "Healthcare", "kim@silverlightclinic.example.com", "North America", "Website Form", 8),
    # no email: cannot be worked, goes to Lead Triage
    ("Max", "Quinn", "Harborlights Bistro", "Food & Beverage", None, "EMEA", "Website Form", 8),
    # region nobody covers: Default rule
    ("Lucia", "Reyes", "Andes Peak Yoga", "Recreation", "lucia@andespeakyoga.example.com", "LATAM", "Free Trial", 15),
    ("Rafa", "Costa", "Ipanema Physio", "Healthcare", "rafa@ipanemaphysio.example.com", "LATAM", "Demo Request", 60),
    # region left blank on the form
    ("Ari", "Weiss", "Lumen Analytics", "Technology", "ari@lumenanalytics.example.com", None, "Content Download", 120),
]
for j, p in enumerate(planted):
    records.append(lead(43 + j, *p))

assert len(records) == 50
assert all("example.com" in r.get("Email", "example.com") for r in records)
out = Path(__file__).resolve().parents[1] / "data" / "leads.json"
out.parent.mkdir(exist_ok=True)
out.write_text(json.dumps({"records": records}, indent=2) + "\n", encoding="utf-8")
print(f"wrote {len(records)} leads to {out}")
