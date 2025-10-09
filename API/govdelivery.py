####################################################################################################
# GovDelivery API Automation Script
#
# DESCRIPTION:
#     This script automates user subscription management with the GovDelivery Communications Cloud.
#     It:
#         - Detects new users and subscribes them to a specified GovDelivery topic.
#         - Identifies users whose details (name, department, description) have changed and updates them.
#         - Detects email address changes and updates the user's email via the API.
#         - Detects disabled accounts and unsubscribes them.
#         - Logs all API activity and emails the log to configured recipients.
#
# TECHNOLOGIES USED:
#     - Python 3
#     - GovDelivery XML API
#     - PowerShell (for AD data extraction)
#     - SMTP (for log delivery)
#
# REQUIREMENTS:
#     - GovDelivery account with API access enabled
#     - API credentials (username/password)
#     - A mappings JSON file for department and description translations
#     - CSV export of Active Directory or similar data source
#     - Python packages: requests, pandas
#
# CONFIGURATION:
#     All sensitive and environment-specific values (API credentials, paths, SMTP settings) are stored
#     in the CONFIG dictionary at the top of the script.
#
# SETUP INSTRUCTIONS:
#     1. Ensure access to the source user data (e.g., Active Directory export via PowerShell).
#     2. Populate `mappings_prod.json` with appropriate department and description mappings.
#     3. Schedule this script to run daily (e.g. using Windows Task Scheduler or cron).
#     4. Ensure outbound access to https://api.govdelivery.com
#
# LINKS:
#     - GovDelivery API Documentation:
#       https://developer.govdelivery.com/api/comm_cloud/
#
# AUTHOR:
#     Oskar Dlugolecki
#
####################################################################################################


import csv
import subprocess
import shutil
import os
import requests
import base64
import pandas as pd
import datetime
from datetime import datetime as dt
import sys
import json
import smtplib
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
import io

# ================== CONFIGURATION SECTION ==================
CONFIG = {
    "USERNAME": "xxxxxxxxxx",
    "PASSWORD": "xxxxxx",
    "ACCOUNT_CODE": "xxxxxx",

    "CREATE_SUBSCRIPTION_URL_TEMPLATE": "https://api.govdelivery.com/api/account/{account}/subscriptions.xml",
    "DELETE_SUBSCRIBER_URL_TEMPLATE": "https://api.govdelivery.com/api/account/{account}/subscribers/{{EncodedEmailAddress}}.xml",
    "UPDATE_SUBSCRIBER_URL_TEMPLATE": "https://api.govdelivery.com/api/account/{account}/subscribers/{{EncodedEmailAddress}}.xml",

    "CREATE_CSV_FILE": "C:/API/new_user_api.csv",
    "DELETE_CSV_FILE": "C:/API/delete_user_api.csv",
    "CHANGE_CSV_FILE": "C:/API/change_user_api.csv",
    "DETAILS_CHANGED_FILE": "C:/API/details_changed.csv",

    "CSV_PATH": "C:/API/ADuserstoday.csv",
    "OLD_CSV_PATH": "C:/API/ADuseryesterday.csv",
    "PS1_SCRIPT_PATH": "C:/API/extract-ad-users-API.ps1",

    "MAPPINGS_FILE": "C:/API/mappings_prod.json",

    "SMTP_SERVER": {"host": "smtp.xxxxxxx", "port": 25},
    "FROM_EMAIL": "xxxxxx@xxxxx.co.uk",
    "TO_EMAILS": [
        "xxxx@xxxxx.co.uk",
        "xxxx@xxxxx.co.uk",
    ]
}
# ============================================================

USERNAME = CONFIG["USERNAME"]
PASSWORD = CONFIG["PASSWORD"]
ACCOUNT_CODE = CONFIG["ACCOUNT_CODE"]

LOGIN = base64.b64encode(f"{USERNAME}:{PASSWORD}".encode()).decode()

CREATE_SUBSCRIPTION_URL = CONFIG["CREATE_SUBSCRIPTION_URL_TEMPLATE"].format(account=ACCOUNT_CODE)
DELETE_SUBSCRIBER_URL = CONFIG["DELETE_SUBSCRIBER_URL_TEMPLATE"].format(account=ACCOUNT_CODE)
UPDATE_SUBSCRIBER_URL = CONFIG["UPDATE_SUBSCRIBER_URL_TEMPLATE"].format(account=ACCOUNT_CODE)

create_csv_file = CONFIG["CREATE_CSV_FILE"]
delete_csv_file = CONFIG["DELETE_CSV_FILE"]
change_csv_file = CONFIG["CHANGE_CSV_FILE"]
details_changed_file = CONFIG["DETAILS_CHANGED_FILE"]

csv_path = CONFIG["CSV_PATH"]
old_csv_path = CONFIG["OLD_CSV_PATH"]
ps1_script_path = CONFIG["PS1_SCRIPT_PATH"]
mappings_file = CONFIG["MAPPINGS_FILE"]

current_time = dt.now().strftime("%Y%m%d_%H%M%S")
log_file_path = f"C:/API/logs/log_{current_time}.txt"

run_ps1 = True

if os.path.exists(mappings_file):
    with open(mappings_file, "r") as file:
        mappings = json.load(file)
        description_mapping = mappings.get("description_mapping", {})
        department_mapping = mappings.get("department_mapping", {})
else:
    print("Mappings file not found! Using empty mappings.")
    description_mapping = {}
    department_mapping = {}

class Logger(object):
    def __init__(self):
        self.terminal = sys.stdout
        self.log_content = io.StringIO()
        sys.stdout = self

    def write(self, message):
        self.terminal.write(message)
        self.log_content.write(message)

    def flush(self):
        self.log_content.flush()
        self.terminal.flush()

    def get_logs(self):
        return self.log_content.getvalue()

def make_api_call(method, url, payload=None, user_email=None):
    headers = {
        "Authorization": f"Basic {LOGIN}",
        "Content-Type": "application/xml"
    }
    try:
        response = requests.request(method, url, headers=headers, data=payload, verify=False)
        log_message = f"API Response | Method: {method} | Status: {response.status_code} | URL: {url} | User: {user_email} | Response: {response.text}"

        if response.status_code != 200:
            print(f"[FAILURE] {log_message}")
        else:
            print(f"[SUCCESS] {log_message}")

        return response
    except Exception as e:
        print(f"[ERROR] API call failed for User: {user_email} | Error: {str(e)}")
        return None

def get_answer_id(value, mapping):
    return mapping.get(value, "")

def read_csv(file_path):
    print(f"Reading CSV file from: {file_path}")
    with open(file_path, mode='r', newline='') as file:
        reader = csv.DictReader(file)
        return list(reader)

def write_csv(file_path, data, fieldnames):
    with open(file_path, mode='w', newline='') as file:
        writer = csv.DictWriter(file, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(data)
    for row in data:
        print(row)

def run_ps1_script(script_path):
    print(f"Running PowerShell script: {script_path}")
    subprocess.run(['powershell.exe', '-File', script_path])

def process_csv():
    if os.path.exists(csv_path):
        shutil.copy(csv_path, old_csv_path)
        old_data = read_csv(old_csv_path)
        old_data = []  # ← if comparing is desired, remove this line

    if run_ps1:
        run_ps1_script(ps1_script_path)
    else:
        print("Skipping PowerShell script execution as run_ps1 is set to False")

    new_data = read_csv(csv_path)
    print(f"New data read: {len(new_data)} records")

    print("\nComparing data")
    users_created_today = []
    changed_emails = []
    disabled_users_today = []
    details_changed = []

    old_data_dict = {user['ObjectGUID']: user for user in old_data}

    for new_user in new_data:
        old_user = old_data_dict.get(new_user['ObjectGUID'])

        if new_user['CreationDate'].strip().lower() == "today":
            users_created_today.append(new_user)

        if old_user:
            if old_user['Destination'] != new_user['Destination']:
                changed_emails.append({'OldEmail': old_user['Destination'], 'NewEmail': new_user['Destination']})

            if (old_user['FirstName'] != new_user['FirstName'] or
                old_user['LastName'] != new_user['LastName'] or
                old_user['Department'] != new_user['Department'] or
                old_user['Description'] != new_user['Description']):
                details_changed.append({
                    'email': new_user['Destination'],
                    'old_first_name': old_user['FirstName'], 
                    'old_last_name': old_user['LastName'], 
                    'old_department': old_user['Department'], 
                    'old_description': old_user['Description'], 
                    'new_first_name': new_user['FirstName'], 
                    'new_last_name': new_user['LastName'], 
                    'new_department': new_user['Department'], 
                    'new_description': new_user['Description']
                })

        if new_user['Disabled'].strip().lower() == "today":
            disabled_users_today.append({'Destination': new_user['Destination']})

    print("\nUsers Created Today:")
    write_csv(create_csv_file, users_created_today, ['Destination', 'FirstName', 'LastName', 'Department', 'Description', 'CreationDate', 'Disabled', 'ObjectGUID'])

    print("\nUsers Who Changed Email Today:")
    write_csv(change_csv_file, changed_emails, ['OldEmail', 'NewEmail'])

    print("\nDisabled Users Today:")
    write_csv(delete_csv_file, disabled_users_today, ['Destination'])

    print("\nUsers with Changed Details:")
    write_csv(details_changed_file, details_changed, ['email', 'old_first_name', 'old_last_name', 'old_department', 'old_description', 'new_first_name', 'new_last_name', 'new_department', 'new_description'])

def create_new_user(email):
    print(f"Creating user: {email}")
    url = CREATE_SUBSCRIPTION_URL
    payload = f"""
    <subscriber>
        <email>{email}</email>
        <send-notifications type='boolean'>false</send-notifications>
        <topics type='array'>
            <topic>
                <code>xxxxxxxx</code>
            </topic>
        </topics>
    </subscriber>
    """
    make_api_call("POST", url, payload)

def process_create_new_user():
    create_df = pd.read_csv(create_csv_file)
    created_users = []

    for _, row in create_df.iterrows():
        email = row["Destination"]
        created_date_str = row["CreationDate"].strip().lower()

        if created_date_str == "today":
            create_new_user(email)
            created_users.append(email)

            first_name = row["FirstName"]
            last_name = row["LastName"]
            description = row["Description"]
            department = row["Department"]

            update_subscriber_details(email, first_name, last_name, 
                                      description_mapping.get(description, description), 
                                      department_mapping.get(department, department))

    return created_users

def delete_user(email):
    print(f"Deleting user: {email}")
    encoded_email = base64.b64encode(email.encode()).decode()
    url = DELETE_SUBSCRIBER_URL.replace("{EncodedEmailAddress}", encoded_email)
    return make_api_call("DELETE", url, user_email=email)

def process_delete_user():
    delete_df = pd.read_csv(delete_csv_file)
    deleted_users = []

    for _, row in delete_df.iterrows():
        email = row["Destination"].strip()
        delete_user(email)
        deleted_users.append(email)

    return deleted_users

def update_email(old_email, new_email):
    print(f"Changing user: {old_email} to {new_email}")
    encoded_old_email = base64.b64encode(old_email.encode()).decode()
    url = UPDATE_SUBSCRIBER_URL.replace("{EncodedEmailAddress}", encoded_old_email)
    payload = f"""
    <subscriber>
        <email>{new_email}</email>
    </subscriber>
    """
    return make_api_call("PUT", url, payload, user_email=old_email)

def process_email_changes():
    change_df = pd.read_csv(change_csv_file)
    changed_users = []

    for _, row in change_df.iterrows():
        old_email = row["OldEmail"].strip()
        new_email = row["NewEmail"].strip()
        update_email(old_email, new_email)
        changed_users.append({'OldEmail': old_email, 'NewEmail': new_email})

    return changed_users

def update_subscriber_details(email, first_name, last_name, description, department):
    mapped_description = description_mapping.get(description, description)
    mapped_department = department_mapping.get(department, department)
    print(f"Updating details for {email}...")
    encoded_email = base64.b64encode(email.encode()).decode()
    url = f"https://api.govdelivery.com/api/account/{ACCOUNT_CODE}/subscribers/{encoded_email}/responses.xml"

    payload = f"""
    <responses type="array">
        <response>
            <question-answer-text>{first_name}</question-answer-text>
            <question-id>xxxxxxxx=</question-id>
        </response>
        <response>
            <question-answer-text>{last_name}</question-answer-text>
            <question-id>xxxxxx=</question-id>
        </response>
        <response>
            <question-id>xxxxxx=</question-id>
            <answer-id>{mapped_department}</answer-id>
        </response>
        <response>
            <question-id>xxxxx=</question-id>
            <answer-id>{mapped_description}</answer-id>
        </response>
    </responses>
    """

    success = make_api_call("PUT", url, payload, user_email=email)

    if success:
        print(f"Success: Updated details for {email}")
    else:
        print(f"Error: Failed to update details for {email}")

def process_update_subscriber_details():
    details_df = pd.read_csv(details_changed_file)
    updated_users = []

    for _, row in details_df.iterrows():
        email = row["email"]
        first_name = row["new_first_name"]
        last_name = row["new_last_name"]
        description = row["new_description"]
        department = row["new_department"]

        update_subscriber_details(email, first_name, last_name, 
                                  description_mapping.get(description, description), 
                                  department_mapping.get(department, department))
        updated_users.append(email)

    return updated_users

def send_log_email(log_content, to_emails, from_email):
    try:
        msg = MIMEMultipart()
        msg['From'] = from_email
        msg['Subject'] = "PROD: API Process Log - " + dt.now().strftime("%Y-%m-%d %H:%M:%S")

        if isinstance(to_emails, str):
            to_emails = [to_emails]

        msg['To'] = ', '.join(to_emails)
        msg.attach(MIMEText(log_content, 'plain'))

        server = CONFIG["SMTP_SERVER"]

        with smtplib.SMTP(server["host"], server["port"]) as smtp:
            smtp.ehlo()
            smtp.sendmail(from_email, to_emails, msg.as_string())
            print(f"Log email sent successfully to {', '.join(to_emails)} via {server['host']}")

    except Exception as e:
        print(f"Failed to send email: {e}")

if __name__ == '__main__':
    logger = Logger()

    try:
        process_csv()
        created_users = process_create_new_user()
        deleted_users = process_delete_user()
        changed_users = process_email_changes()
        updated_users = process_update_subscriber_details()

        log_content = logger.get_logs()

        send_log_email(log_content, CONFIG["TO_EMAILS"], CONFIG["FROM_EMAIL"])

    finally:
        sys.stdout = logger.terminal
