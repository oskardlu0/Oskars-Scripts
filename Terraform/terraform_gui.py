####################################################################################################
# Terraform GUI Automation Tool
#
# Description:
# ------------
# This is a GUI-based automation tool built with Python and Tkinter to manage and upgrade 
# Terraform infrastructure code
#
# Features:
# ---------
# ✓ Check and report Terraform module versions used across directories
# ✓ Upgrade Terraform module source versions automatically
# ✓ Check and upgrade provider versions in `provider.tf` files
# ✓ Check and upgrade `.terraform-version` files
# ✓ Generate plan/apply command scripts
# ✓ Rename plan output files based on result contents
# ✓ Generate `terraform state rm/import` commands
# ✓ Delete and re-distribute `secrets.tf` files across module directories
#
# Outputs:
# --------
# - CSV reports in the `C:\temp\GUI Output\` folder
# - Shell scripts to execute terraform plan/apply
# - Text files with state import commands
#
# Requirements:
# -------------
# - Python 3.7+
# - Libraries: pandas
# - Terraform installed
# - Assumes a specific Git repository structure (see "Important Notes" below)
#
# How to Use:
# -----------
# 1. Run the script: `python terraform_gui.py`
# 2. Use the GUI to:
#    - Check versions of modules/providers/terraform
#    - Upgrade versions as needed
#    - Generate `plan` and `apply` command files
#    - Manage secrets files
#    - Generate import commands for state refresh
#
# Important Notes:
# ----------------
# ⚠️ WARNING: You *must* adjust the following hardcoded paths and variables to fit your environment:
#
#   - `GIT_ROOT_DRIVE` (currently set to `'D:'`)
#   - `TERRAFORM_CONTROL_REPO` (e.g., `'vmw-terraform-control-prod'`)
#   - Any path references to `'C:\\temp\\GUI Output'` or similar
#   - Module source URL: `MODULE_SOURCE_URL`
#
#   These values assume a very specific Git repo structure, local drive setup, and file layout.
#   If your environment differs, you **must update** these paths for the script to function properly.
#
# Example directory layout expected:
# ----------------------------------
# D:\
# └── Git\
#     └── your_username\
#         └── vmw-terraform-control-prod\
#             ├── Primary Data Centre\
#             └── Secondary Data Centre\
#
####################################################################################################


# CONFIG
GIT_ROOT_DRIVE = 'D:'
TERRAFORM_CONTROL_REPO = 'vmw-terraform-control-prod'
TEMP_OUTPUT_DIR = 'C:\\temp\\GUI Output'
MODULE_SOURCE_URL = 'git@github.com:YOURS/vmw-vspherevm-terraform-module-3.5.0.git'
PRIMARY_DC = 'Primary Data Centre'
SECONDARY_DC = 'Secondary Data Centre'

import os
import re
import csv
import pandas as pd
import shutil
from tkinter import *
from tkinter import messagebox, simpledialog
from tkinter.font import Font

def version_tuple(version):
    return tuple(map(int, (version[1:].split("."))))

def pr_check_module():
    check_module('Primary Data Centre', pr_version_entry)

def se_check_module():
    check_module('Secondary Data Centre', se_version_entry)

def pr_upgrade_module():
    upgrade_module('Primary Data Centre', pr_upgrade_version_entry)

def se_upgrade_module():
    upgrade_module('Secondary Data Centre', se_upgrade_version_entry)

def pr_check_provider():
    check_provider('Primary Data Centre', pr_provider_version_entry)

def se_check_provider():
    check_provider('Secondary Data Centre', se_provider_version_entry)

def pr_upgrade_provider():
    upgrade_provider('Primary Data Centre', pr_upgrade_provider_version_entry)

def se_upgrade_provider():
    upgrade_provider('Secondary Data Centre', se_upgrade_provider_version_entry)

def pr_check_terraform():
    check_terraform('Primary Data Centre', pr_terraform_version_entry)

def se_check_terraform():
    check_terraform('Secondary Data Centre', se_terraform_version_entry)

def pr_upgrade_terraform():
    upgrade_terraform('Primary Data Centre', pr_upgrade_terraform_version_entry)

def se_upgrade_terraform():
    upgrade_terraform('Secondary Data Centre', se_upgrade_terraform_version_entry)


def check_module(data_centre, version_entry):
    current_dir = os.getcwd()
    username = os.path.basename(os.path.dirname(current_dir))
    dir_to_scan = os.path.join(GIT_ROOT_DRIVE, os.sep, 'Git', username, TERRAFORM_CONTROL_REPO, data_centre, '')
    pattern = rf'source = "{MODULE_SOURCE_URL}\?ref=(v\d+\.\d+(\.\d+)?)"'
    version_to_check = version_tuple(version_entry.get())
    output = []
    for root, dirs, files in os.walk(dir_to_scan):
        for file in files:
            if file.endswith(".tf"):
                file_path = os.path.join(root, file)
                with open(file_path, 'r') as f:
                    content = f.read()
                    match = re.search(pattern, content)
                    if match:
                        version = version_tuple(match.group(1))
                        if version < version_to_check:
                            version_str = '.'.join(map(str, version))
                            output.append([os.path.dirname(file_path), os.path.basename(file_path), version_str])
    os.makedirs(TEMP_OUTPUT_DIR, exist_ok=True)
    csv_file_path = os.path.join(TEMP_OUTPUT_DIR, f'{data_centre}_module_versions.csv')
    with open(csv_file_path, 'w', newline='') as csvfile:
        writer = csv.writer(csvfile)
        writer.writerow(['Path', 'File Name', 'Version'])
        for row in output:
            writer.writerow(row)
    df = pd.read_csv(csv_file_path)
    version_counts = df['Version'].value_counts().to_dict()
    version_counts_str = '\n'.join([f'{k}: {v}' for k, v in version_counts.items()])
    messagebox.showinfo('Check Module', f'Module check completed for {data_centre}.\nResults saved to {csv_file_path}.\nVersion counts:\n{version_counts_str}')

def upgrade_module(data_centre, upgrade_version_entry):
    current_dir = os.getcwd()
    username = os.path.basename(os.path.dirname(current_dir))
    dir_to_scan = os.path.join(GIT_ROOT_DRIVE, os.sep, 'Git', username, TERRAFORM_CONTROL_REPO, data_centre, '')
    pattern = rf'source = "{MODULE_SOURCE_URL}\?ref=(v\d+\.\d+(\.\d+)?)"'
    new_version = upgrade_version_entry.get()
    for root, dirs, files in os.walk(dir_to_scan):
        for file in files:
            if file.endswith(".tf"):
                file_path = os.path.join(root, file)
                with open(file_path, 'r') as f:
                    content = f.read()
                    match = re.search(pattern, content)
                    if match:
                        old_version = match.group(1).replace(">= ", "")
                        content = re.sub(pattern, f'source = "{MODULE_SOURCE_URL}?ref={new_version}"', content)
                        with open(file_path, 'w') as f:
                            f.write(content)
                        print(f"Updated File: {file_path}, Old Version: {old_version}, New Version: {new_version}")

def check_provider(data_centre, provider_version_entry):
    current_dir = os.getcwd()
    username = os.path.basename(os.path.dirname(current_dir))
    dir_to_scan = os.path.join(GIT_ROOT_DRIVE, os.sep, 'Git', username, TERRAFORM_CONTROL_REPO, data_centre, '')
    pattern = r'version = "(>= \d+\.\d+(\.\d+)?)"'
    version_to_check = version_parse(provider_version_entry.get().replace(">= ", ""))
    output = []
    for root, dirs, files in os.walk(dir_to_scan):
        for file in files:
            if file == 'provider.tf':
                file_path = os.path.join(root, file)
                with open(file_path, 'r') as f:
                    content = f.read()
                    match = re.search(pattern, content)
                    if match:
                        version = version_parse(match.group(1).replace(">= ", ""))
                        if version < version_to_check:
                            output.append([os.path.dirname(file_path), os.path.basename(file_path), str(version)])
    os.makedirs(TEMP_OUTPUT_DIR, exist_ok=True)
    csv_file_path = os.path.join(TEMP_OUTPUT_DIR, f'{data_centre}_provider_versions.csv')
    with open(csv_file_path, 'w', newline='') as csvfile:
        writer = csv.writer(csvfile)
        writer.writerow(['Path', 'File Name', 'Version'])
        for row in output:
            writer.writerow(row)
    df = pd.read_csv(csv_file_path)
    version_counts = df['Version'].value_counts().to_dict()
    version_counts_str = '\n'.join([f'{k}: {v}' for k, v in version_counts.items()])
    messagebox.showinfo('Check Provider', f'Provider check completed for {data_centre}.\nResults saved to {csv_file_path}.\nVersion counts:\n{version_counts_str}')

def upgrade_provider(data_centre, upgrade_provider_version_entry):
    current_dir = os.getcwd()
    username = os.path.basename(os.path.dirname(current_dir))
    dir_to_scan = os.path.join(GIT_ROOT_DRIVE, os.sep, 'Git', username, TERRAFORM_CONTROL_REPO, data_centre, '')
    pattern = r'(version = ")(>= \d+\.\d+(\.\d+)?)(")'
    new_version = upgrade_provider_version_entry.get()
    for root, dirs, files in os.walk(dir_to_scan):
        for file in files:
            if file == 'provider.tf':
                file_path = os.path.join(root, file)
                with open(file_path, 'r') as f:
                    content = f.read()
                    blocks = content.split('required_providers')
                    for i in range(1, len(blocks)):
                        block = blocks[i]
                        match = re.search(pattern, block)
                        if match:
                            old_version = match.group(2).replace(">= ", "")
                            block = re.sub(pattern, f'version = ">= {new_version}"', block)
                            blocks[i] = block
                    content = 'required_providers'.join(blocks)
                    with open(file_path, 'w') as f:
                        f.write(content)
                    print(f"Updated File: {file_path}, New Version: {new_version}")

def check_terraform(data_centre, version_entry):
    current_dir = os.getcwd()
    username = os.path.basename(os.path.dirname(current_dir))
    dir_to_scan = os.path.join(GIT_ROOT_DRIVE, os.sep, 'Git', username, TERRAFORM_CONTROL_REPO, data_centre, '')
    pattern = r'(\d+\.\d+(\.\d+)?)'
    version_to_check = version_parse(version_entry.get())
    output = []
    for root, dirs, files in os.walk(dir_to_scan):
        for file in files:
            if file == '.terraform-version':
                file_path = os.path.join(root, file)
                with open(file_path, 'r') as f:
                    content = f.read().strip()
                    match = re.search(pattern, content)
                    if match:
                        version = version_parse(match.group(0))
                        if version < version_to_check:
                            output.append([os.path.dirname(file_path), os.path.basename(file_path), str(version)])
    os.makedirs(TEMP_OUTPUT_DIR, exist_ok=True)
    csv_file_path = os.path.join(TEMP_OUTPUT_DIR, f'{data_centre}_terraform_versions.csv')
    with open(csv_file_path, 'w', newline='') as csvfile:
        writer = csv.writer(csvfile)
        writer.writerow(['Path', 'File Name', 'Version'])
        for row in output:
            writer.writerow(row)
    df = pd.read_csv(csv_file_path)
    version_counts = df['Version'].value_counts().to_dict()
    version_counts_str = '\n'.join([f'{k}: {v}' for k, v in version_counts.items()])
    messagebox.showinfo('Check Terraform', f'Terraform check completed for {data_centre}.\nResults saved to {csv_file_path}.\nVersion counts:\n{version_counts_str}')

def upgrade_terraform(data_centre, new_version_entry):
    current_dir = os.getcwd()
    username = os.path.basename(os.path.dirname(current_dir))
    dir_to_scan = os.path.join(GIT_ROOT_DRIVE, os.sep, 'Git', username, TERRAFORM_CONTROL_REPO, data_centre, '')
    new_version = new_version_entry.get() 
    for root, dirs, files in os.walk(dir_to_scan):
        for file in files:
            if file == '.terraform-version':
                file_path = os.path.join(root, file)
                with open(file_path, 'r') as f:
                    old_version = f.read().strip()
                with open(file_path, 'w') as f:
                    f.write(new_version)
                print(f"File Path: {file_path}, Old Version: {old_version}, New Version: {new_version}")
    print(f"Terraform upgrade completed for {data_centre}.")


def convert_to_linux_path(path):
    path = path.lstrip('D:\\')
    path = path.replace('\\', '/')
    path = path.rstrip()
    return path


def generate_plan(data_centre, filename):
    output_file = os.path.join(TEMP_OUTPUT_DIR, filename)

    with open(output_file, 'w') as outfile:
        outfile.write('Commands\n')

        current_dir = os.getcwd()
        username = os.path.basename(os.path.dirname(current_dir))
        dir_to_scan = os.path.join(GIT_ROOT_DRIVE, os.sep, 'Git', username, TERRAFORM_CONTROL_REPO, data_centre, '')

        for root, dirs, files in os.walk(dir_to_scan):
            dirs[:] = [d for d in dirs if d != '.terraform']

            for file in files:
                if file == '.terraform-version':
                    path = os.path.dirname(os.path.join(root, file))
                    linux_path = convert_to_linux_path(path)
                    full_linux_path = f"/D/{linux_path}"
                    txt_file_path = '-'.join(full_linux_path.split('/')[full_linux_path.split('/').index(data_centre)+1:])
                    outfile.write(f'cd "{full_linux_path}"\n')
                    outfile.write('terraform init -upgrade\n')
                    outfile.write('sleep 3\n')
                    outfile.write(f'./form.sh plan -no-color > "/c/temp/GUI Output/{data_centre}/{txt_file_path}.txt"\n')
                    outfile.write('sleep 3\n\n')

    messagebox.showinfo('Generate Plan', f"Commands written to {output_file}")


def rename_files(directory):
    for filename in os.listdir(directory):
        if filename.endswith(".txt"):
            filepath = os.path.join(directory, filename)
            with open(filepath, 'r') as file:
                content = file.read()

            if re.search(r'\b[1-9][0-9]* to change\b', content):
                new_filename = 'change-' + filename
            elif 'No changes.' in content:
                new_filename = 'success-' + filename
            elif content == '':
                new_filename = 'empty-' + filename
            elif 'Planning failed.' in content:
                new_filename = 'failed-' + filename
            else:
                new_filename = 'investigate-' + filename

            if new_filename != filename:
                os.rename(filepath, os.path.join(directory, new_filename))


def generate_apply(data_centre, filename):
    output_file = os.path.join(TEMP_OUTPUT_DIR, filename)

    with open(output_file, 'w') as outfile:
        outfile.write('Commands\n')

        current_dir = os.getcwd()
        username = os.path.basename(os.path.dirname(current_dir))
        dir_to_scan = os.path.join(GIT_ROOT_DRIVE, os.sep, 'Git', username, TERRAFORM_CONTROL_REPO, data_centre, '')

        for root, dirs, files in os.walk(dir_to_scan):
            dirs[:] = [d for d in dirs if d != '.terraform']

            for file in files:
                if file == '.terraform-version':
                    path = os.path.dirname(os.path.join(root, file)) 
                    linux_path = convert_to_linux_path(path)
                    full_linux_path = f"/D/{linux_path}"
                    txt_file_path = '-'.join(full_linux_path.split('/')[full_linux_path.split('/').index(data_centre)+1:])
                    outfile.write(f'cd "{full_linux_path}"\n')
                    outfile.write('terraform init -upgrade\n')
                    outfile.write('sleep 3\n')
                    outfile.write(f'./form.sh apply\n')
                    outfile.write('sleep 3\n\n')

    messagebox.showinfo('Generate Apply', f"Commands written to {output_file}")


def state_refresh_generator():
    import os
    import re
    import subprocess

    original_dir = os.getcwd()

    dir_path = simpledialog.askstring("Input", "What directory would you like to run this script in?", parent=root)

    if dir_path is not None:  
        dir_path_parts = dir_path.split("\\")
        if "Primary Data Centre" in dir_path_parts:
            index = dir_path_parts.index("Primary Data Centre")
            dir_path_parts = dir_path_parts[index:]
            dir_path = "/".join(dir_path_parts) 

        os.chdir(os.path.join(original_dir, dir_path))

        module_pattern = re.compile(r'module "(.*?)"')
        varfile_pattern = re.compile(r'--var-file (.*?\.tfvars)')

        files = os.listdir('.')

        var_file = None
        if "form.sh" in files:
            with open("form.sh", 'r') as f:
                content = f.read()
                match = varfile_pattern.search(content)
                if match:
                    var_file = match.group(1)

        output = []
        for file in files:
            if file.endswith(".tf"):
                with open(file, 'r') as f:
                    content = f.read()
                    match = module_pattern.search(content)
                    if match:
                        module_name = match.group(1)
                        module_name_replace = module_name.replace("_", "-") 
                        output.append(f'\n{module_name}')
                        output.append(f'terraform state rm module.{module_name}.vsphere_virtual_machine.vm[0]')
                        if var_file is not None:  
                            output.append(f'terraform import --var-file {var_file} module.{module_name}.vsphere_virtual_machine.vm[0] "/Primary Data Centre/vm/{dir_path}/{module_name_replace}"')

        os.chdir(original_dir)

        output_dir = TEMP_OUTPUT_DIR
        os.makedirs(output_dir, exist_ok=True)
        output_file = os.path.join(output_dir, f'{dir_path.replace(os.sep, "_").replace("/", "_")}.txt')
        with open(output_file, 'w') as f:
            f.write('\n'.join(output))

        subprocess.Popen([output_file], shell=True)


def delete_secrets():
    current_dir = os.getcwd()
    username = os.path.basename(os.path.dirname(current_dir))
    dir_to_scan = os.path.join(GIT_ROOT_DRIVE, os.sep, 'Git', username, TERRAFORM_CONTROL_REPO)
    for root, dirs, files in os.walk(dir_to_scan):
        for file in files:
            if file == 'secrets.tf':
                file_path = os.path.join(root, file)
                os.remove(file_path)
                print(f"Deleted File: {file_path}")


def generate_and_distribute_secrets(data_centre):
    current_dir = os.getcwd()
    username = os.path.basename(os.path.dirname(current_dir))
    base_dir = os.path.join(GIT_ROOT_DRIVE, os.sep, 'Git', username, TERRAFORM_CONTROL_REPO, data_centre)
    directories = ['App', 'Data', 'Management Zone', 'Web']
    for directory in directories:
        secrets_content = simpledialog.askstring("Input", f"Copy {directory} secrets.tf from the {data_centre} folder in Keeper and paste below and press OK")
        if secrets_content is None:
            return
        dir_path = os.path.join(base_dir, directory)
        os.makedirs(dir_path, exist_ok=True)
        secrets_file_path = os.path.join(dir_path, 'secrets.tf')
        with open(secrets_file_path, 'w') as f:
            f.write(secrets_content)
        count = 0
        for root, dirs, files in os.walk(dir_path):
            if root != dir_path and '.terraform' not in root and any(fname.endswith('.tf') for fname in files):
                dest_path = os.path.join(root, 'secrets.tf')
                shutil.copy(secrets_file_path, dest_path)
                print(f"Created File: {dest_path}")
                count += 1
        messagebox.showinfo('Generate Secrets', f'Generated {count} secrets.tf files in {directory} directory')


root = Tk()
root.geometry('1200x800') 
root.title("Terraform GUI")
current_dir = os.getcwd()
username = os.path.basename(os.path.dirname(current_dir))
base_dir = os.path.join('D:', os.sep, 'Git', username, 'vmw-terraform-control-prod', 'GUI')
icon_path = os.path.join(base_dir, 'icon.ico')
root.iconbitmap(icon_path)


canvas = Canvas(root, width=1200, height=600)
canvas.pack()

canvas.create_line(600, 0, 600, 600) 
canvas.create_line(0, 300, 1200, 300)  

pr_check_frame = Frame(root, width=600, height=300)
pr_check_frame.place(x=0, y=0)

se_check_frame = Frame(root, width=600, height=300)
se_check_frame.place(x=600, y=0)

pr_upgrade_frame = Frame(root, width=600, height=300)
pr_upgrade_frame.place(x=0, y=300)

se_upgrade_frame = Frame(root, width=600, height=300)
se_upgrade_frame.place(x=600, y=300)

title_font = Font(size=14, weight='bold')

# PR Checks
Label(pr_check_frame, text="PR Checks", font=title_font).grid(row=0, column=0, columnspan=3)

Label(pr_check_frame, text="PR Module Version to check:").grid(row=1, column=0)
pr_version_entry = Entry(pr_check_frame)
pr_version_entry.grid(row=1, column=1)
Button(pr_check_frame, text="PR Check Module", command=pr_check_module).grid(row=1, column=2)

Label(pr_check_frame, text="PR Provider Version to check:").grid(row=2, column=0)
pr_provider_version_entry = Entry(pr_check_frame)
pr_provider_version_entry.grid(row=2, column=1)
Button(pr_check_frame, text="PR Check Provider", command=pr_check_provider).grid(row=2, column=2)

Label(pr_check_frame, text="PR Terraform Version to check:").grid(row=3, column=0)
pr_terraform_version_entry = Entry(pr_check_frame)
pr_terraform_version_entry.grid(row=3, column=1)
Button(pr_check_frame, text="PR Check Terraform", command=pr_check_terraform).grid(row=3, column=2)

# SE Checks
Label(se_check_frame, text="SE Checks", font=title_font).grid(row=0, column=0, columnspan=3)

Label(se_check_frame, text="SE Module Version to check:").grid(row=1, column=0)
se_version_entry = Entry(se_check_frame)
se_version_entry.grid(row=1, column=1)
Button(se_check_frame, text="SE Check Module", command=se_check_module).grid(row=1, column=2)

Label(se_check_frame, text="SE Provider Version to check:").grid(row=2, column=0)
se_provider_version_entry = Entry(se_check_frame)
se_provider_version_entry.grid(row=2, column=1)
Button(se_check_frame, text="SE Check Provider", command=se_check_provider).grid(row=2, column=2)

Label(se_check_frame, text="SE Terraform Version to check:").grid(row=3, column=0)
se_terraform_version_entry = Entry(se_check_frame)
se_terraform_version_entry.grid(row=3, column=1)
Button(se_check_frame, text="SE Check Terraform", command=se_check_terraform).grid(row=3, column=2)

# PR Upgrade
Label(pr_upgrade_frame, text="PR Upgrade", font=title_font).grid(row=0, column=0, columnspan=3)

Label(pr_upgrade_frame, text="Update all PR Modules to version:").grid(row=1, column=0)
pr_upgrade_version_entry = Entry(pr_upgrade_frame)
pr_upgrade_version_entry.grid(row=1, column=1)
Button(pr_upgrade_frame, text="PR Upgrade Module", command=pr_upgrade_module).grid(row=1, column=2)

Label(pr_upgrade_frame, text="Update all PR Providers to version:").grid(row=2, column=0)
pr_upgrade_provider_version_entry = Entry(pr_upgrade_frame)
pr_upgrade_provider_version_entry.grid(row=2, column=1)
Button(pr_upgrade_frame, text="PR Upgrade Provider", command=pr_upgrade_provider).grid(row=2, column=2)

Label(pr_upgrade_frame, text="Update all PR Terraform to version:").grid(row=3, column=0)
pr_upgrade_terraform_version_entry = Entry(pr_upgrade_frame)
pr_upgrade_terraform_version_entry.grid(row=3, column=1)
Button(pr_upgrade_frame, text="PR Upgrade Terraform", command=pr_upgrade_terraform).grid(row=3, column=2)

Button(pr_upgrade_frame, text="Generate PR Plan", command=lambda: generate_plan('Primary Data Centre', 'pr_plan_script.csv')).grid(row=4, column=2)
Button(pr_upgrade_frame, text="Check PR Plan Files", command=lambda: rename_files('C:\\temp\\GUI Output\\Primary Data Centre')).grid(row=5, column=2)
Button(pr_upgrade_frame, text="Generate PR Apply", command=lambda: generate_apply('Primary Data Centre', 'pr_apply_script.csv')).grid(row=6, column=2)

# SE Upgrade
Label(se_upgrade_frame, text="SE Upgrade", font=title_font).grid(row=0, column=0, columnspan=3)

Label(se_upgrade_frame, text="Update all SE Modules to version:").grid(row=1, column=0)
se_upgrade_version_entry = Entry(se_upgrade_frame)
se_upgrade_version_entry.grid(row=1, column=1)
Button(se_upgrade_frame, text="SE Upgrade Module", command=se_upgrade_module).grid(row=1, column=2)

Label(se_upgrade_frame, text="Update all SE Providers to version:").grid(row=2, column=0)
se_upgrade_provider_version_entry = Entry(se_upgrade_frame)
se_upgrade_provider_version_entry.grid(row=2, column=1)
Button(se_upgrade_frame, text="SE Upgrade Provider", command=se_upgrade_provider).grid(row=2, column=2)

Label(se_upgrade_frame, text="Update all SE Terraform to version:").grid(row=3, column=0)
se_upgrade_terraform_version_entry = Entry(se_upgrade_frame)
se_upgrade_terraform_version_entry.grid(row=3, column=1)
Button(se_upgrade_frame, text="SE Upgrade Terraform", command=se_upgrade_terraform).grid(row=3, column=2)

Button(se_upgrade_frame, text="Generate SE Plan", command=lambda: generate_plan('Secondary Data Centre', 'se_plan_script.csv')).grid(row=4, column=2)
Button(se_upgrade_frame, text="Check SE Plan Files", command=lambda: rename_files('C:\\temp\\GUI Output\\Secondary Data Centre')).grid(row=5, column=2)
Button(se_upgrade_frame, text="Generate SE Apply", command=lambda: generate_apply('Secondary Data Centre', 'se_apply_script.csv')).grid(row=6, column=2)

# Bonus Scripts

bonus_scripts_frame = Frame(root, width=1200, height=300)
bonus_scripts_frame.place(x=0, y=600)

Label(bonus_scripts_frame, text="Bonus Scripts", font=title_font).grid(row=0, column=0, columnspan=3)

Label(bonus_scripts_frame, text="Generate state rm and import commands for whole dir:").grid(row=1, column=0)
Button(bonus_scripts_frame, text="Generate", command=state_refresh_generator).grid(row=1, column=1)

#Fix Secrets.tf file

fix_secrets_frame = Frame(root, width=600, height=300)
fix_secrets_frame.place(x=600, y=600)
Label(fix_secrets_frame, text="Fix all secret.tf files", font=title_font).grid(row=0, column=0, columnspan=3)

Label(fix_secrets_frame, text="Step 1):").grid(row=1, column=0)
Button(fix_secrets_frame, text="Delete all secrets.tf files", command=delete_secrets).grid(row=1, column=1)

Label(fix_secrets_frame, text="Step 2):").grid(row=3, column=0)
Button(fix_secrets_frame, text="Generate Secrets for Primary Data Centre", command=lambda: generate_and_distribute_secrets('Primary Data Centre')).grid(row=3, column=1)

Label(fix_secrets_frame, text="Step 3):").grid(row=4, column=0)
Button(fix_secrets_frame, text="Generate Secrets for Secondary Data Centre", command=lambda: generate_and_distribute_secrets('Secondary Data Centre')).grid(row=4, column=1)



root.mainloop()

