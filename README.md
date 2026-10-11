# Palworld Server on AWS with Terraform

A hands-on lab for anyone learning Infrastructure as Code (IaC) on AWS. You'll use Terraform to build a Palworld dedicated server, then configure and run it.

## What we're building

- A Palworld server running on **Windows Server 2025** on an AWS EC2 instance
- Networking in the **default VPC**, to keep the demo simple
- A **security group** that restricts access to your current public IP, found using https://api.ipify.org/
- A **bootstrap script** that drops PowerShell scripts onto the instance to install PowerShell 7, SteamPS, and SteamCMD, which you'll use to install and run the Palworld server

## Before you start

You'll need to create your own AWS account and install a few tools. The prerequisites section covers all of it. The lab launches a real EC2 instance, which bills while it runs, so be sure to run `terraform destroy` when you're done.

---

## Prerequisites

Before we build anything, you need an AWS account, a way for Terraform to log in to it, and a few tools on your machine. Heads up: this lab spins up an EC2 instance, and it's coin operated (pay as you go), so there is a cost, but we will tear it down at the end.

### 1. Create an AWS account

Sign up at https://signin.aws.amazon.com/signup?request_type=register

### 2. Generate an access key

Terraform needs credentials to create things in your account for you.

1. Sign in to the AWS web portal and click your account name in the top right, then **Security credentials**.
2. Scroll down to **Access keys** and click **Create access key**.
3. Save both the access key ID and the secret access key somewhere safe. You only get one chance to see the secret.

> **Root vs. IAM:** Best practice is to create an IAM user and generate the key there. For this lab I'm just using the root user to keep things simple. Root keys can do anything in the account, so if this is an account you care about, use an IAM user instead. Either way, delete the access key when you're done with the lab.

### 3. Install and configure the AWS CLI

Install it using the instructions here: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html#getting-started-install-instructions

Then, in PowerShell, run:

```powershell
aws configure
```

When prompted, enter:

```
AWS Access Key ID:      <your access key>
AWS Secret Access Key:  <your secret access key>
Default region name:    us-east-2
Default output format:  (leave blank)
```

Stick with `us-east-2`. The code is written for that region, and AMI IDs are region-specific.

Now check that it worked:

```powershell
aws sts get-caller-identity
```

This prints your account ID and ARN. If the account ID matches yours, you're good.

### 4. Create the EC2 key pair

The server gets its Administrator password encrypted with a key pair, and the code expects one to already exist.

1. In the AWS console, switch to the **us-east-2 (Ohio)** region.
2. Go to **EC2 → Network & Security → Key Pairs → Create key pair**.
3. Name it exactly `pworld_kp`, choose **RSA** and **.pem**, and create it.
4. Keep the downloaded `.pem` file. You'll upload it later to decrypt the server password.

> **Using your own key pair:** You can name it whatever you like, or reuse an existing one in `us-east-2`. Just update `key_name` in `palworld_main.tf` to match.

### 5. Install Terraform

1. Download Terraform from https://developer.hashicorp.com/terraform/install
2. Unzip it and put `terraform.exe` in a folder you'll remember.
3. Add that folder to your system `PATH`.
4. Open a new PowerShell window and confirm the install:

```powershell
terraform -v
```

### 6. Install VS Code

Install VS Code, then add the **HashiCorp Terraform** extension for syntax highlighting and validation.

### 7. Grab the lab files

Get a copy of this repo on your machine. Either:

- **Download ZIP:** on the repo page, click **Code → Download ZIP**, then extract it.
- **Clone it**, if you have Git installed:

```powershell
git clone https://github.com/JPBTriesToIT/palworld_server_lab.git
```

Open the resulting folder in VS Code.

> **Note:** `Get-PubIP.ps1` runs on *your* machine during `plan`/`apply` to find your public IP, and the code calls Windows PowerShell (`powershell`). If you're on Mac or Linux, install PowerShell 7 and change `powershell` to `pwsh` in `palworld_main.tf`.

### 8. Initialize and plan

Open the terminal in VS Code and run:

```powershell
terraform init
```

This downloads the providers Terraform needs (AWS, plus one that lets us run the IP script). Then:

```powershell
terraform plan
```

This is a dry run. It lists everything Terraform *would* create without actually creating it. We won't run `terraform apply` yet. First, let's walk through the code so you know what each piece does.

---

## The Terraform code

Everything lives in `palworld_main.tf`. It reads top to bottom: setup, lookups, resources, outputs. Almost like a recipe.

### Provider

```hcl
provider "aws" {
  region = "us-east-2"
}
```

Sets AWS as the provider and `us-east-2` as the region. Credentials come from the `aws configure` step, so no keys go in the code.

### Default VPC

```hcl
#use default VPC
data "aws_vpc" "default" {
  default = true
}
```

A `data` block reads something that already exists instead of creating it. Every AWS account has a default VPC in each region, and we use it here to keep the demo simple. For anything beyond a lab, you'd build your own VPC and subnets.

### Public IP lookup

```hcl
#fetch the public IP of the machine via Get-PubIP.ps1 script
data "external" "public_ip" {
  program = [
    "powershell",
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    "${path.module}/Get-PubIP.ps1"
  ] 
}

# source_prefix will be used to allow RDP access from the current public IP of the machine running the script
locals {
  source_prefix = data.external.public_ip.result.sourcePrefix
}
```

This data block runs `Get-PubIP.ps1` on your local machine:

```powershell
# Determine the public IP of the machine running the script
$myIP = (Invoke-RestMethod -Uri "https://api.ipify.org").Trim()
$sourcePrefix = "$myIP/32"
@{ sourcePrefix = $sourcePrefix } | ConvertTo-Json
```

The script gets your public IP from `api.ipify.org`, appends `/32`, and returns it to Terraform as JSON. The `locals` block exposes it as `local.source_prefix` for the rules below.

It runs on every `plan` and `apply`, so if your IP changes, re-apply to update the firewall rules.

### Security group

```hcl
# create NSG
resource "aws_security_group" "pworld_lab_nsg" {
  name        = "pworld_lab_nsg"
  description = "Allow inbound RDP, Game server and API traffic"
  #vpc_id      = aws_vpc.pers_tform_lab_vpc.id
  vpc_id      = data.aws_vpc.default.id # Replace with your VPC ID

  #Allow Inbound traffic to desired Port(s), from desired IP Range(s)
  ingress {   #Allow RDP Access from source_prefix acquired above
    description      = "RDP"
    from_port        = 3389
    to_port          = 3389
    protocol         = "tcp"
    cidr_blocks      = [local.source_prefix]
  }

  ingress {   #Allow Palworld inbound Access from source_prefix acquired above
    description      = "Palworld inbound"
    from_port        = 8211
    to_port          = 8211
    protocol         = "udp"
    cidr_blocks      = [local.source_prefix]
  }

  ingress {   #Allow Palworld API inbound Access from source_prefix acquired above
    description      = "Palworld API inbound"
    from_port        = 8212
    to_port          = 8212
    protocol         = "tcp"
    cidr_blocks      = [local.source_prefix]
  }

  egress {     #Allow All Outbound Traffic
    description      = "All Outbound"
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
  }

  tags = {
    Name = "pworld_lab_nsg"
  }
}
```

This is the server's security group, think of it like a firewall. It's attached to the default VPC.

Three inbound rules, each limited to your IP:

- **3389/tcp:** RDP, for remote access to the Windows server
- **8211/udp:** Palworld game traffic
- **8212/tcp:** Palworld API

The outbound rule allows all traffic so the server can download SteamCMD, game files, and updates. Security groups are stateful, so replies to allowed inbound traffic are permitted automatically.

To let friends join the game, add their IPs to the `cidr_blocks` list on the 8211 rule.

### EC2 instance

```hcl
resource "aws_instance" "pworld_lab_instance" {
  ami                         = "ami-0daff962b1c050d36" #Microsoft Windows 2025 Base
  #ami                         = "ami-0a309571b4f421554" #Microsoft Windows 2022 Base
  #instance_type               = "g4dn.xlarge" #Nvidia GPU instance for Palworld server
  instance_type               = "t3.xlarge" #Non-GPU instance for Palworld server
  key_name                    = "pworld_kp"
  associate_public_ip_address = true
  vpc_security_group_ids     = [aws_security_group.pworld_lab_nsg.id]

  root_block_device {
    volume_size = 100 # Only changing the size
  }
```

The server itself:

- **`ami`:** the OS image, Windows Server 2025 Base. The 2022 image is commented out as an alternative. AMI IDs are region-specific, so these work only in `us-east-2`.
- **`instance_type`:** `t3.xlarge` (4 vCPU, 16 GB RAM), enough for a small Palworld server. The GPU option is commented out since a dedicated server doesn't need one.
- **`key_name`:** the key pair from the prerequisites, used to encrypt the Windows Administrator password. If you named yours something else, change this value to match.
- **`associate_public_ip_address`:** assigns a public IP. It changes if you stop and start the instance.
- **`vpc_security_group_ids`:** attaches the security group above.
- **`root_block_device`:** increases the disk to 100 GB to fit the game files.

```hcl
# Web server deployment script (uncomment to use)
# user_data = <<-EOF
#    <powershell>
#    # Test script that deploys a web server (check via http://<instance-public-ip>) and creates a file to indicate deployment
#    New-Item -Path "C:\deployed.txt" -ItemType File -Value "Deployed at $(Get-Date)"
#    Install-WindowsFeature -Name Web-Server -IncludeManagementTools
#    </powershell>
# EOF
  user_data = templatefile("${path.module}/bootstrap.tpl", {
    script_content = filebase64("${path.module}/Install-WinGetAndPowerShell7.ps1")
    steamcmd_script = filebase64("${path.module}/Install-SteamPSandSteamCMD.ps1")
  })

  tags = {
    Name = "pworld_lab_instance"
  }
}
```

`user_data` is a script AWS runs once, on the instance's first boot. The commented-out block is a simple web server test for trying `user_data` on its own.

The active version uses `templatefile` to fill in `bootstrap.tpl` with our two PowerShell scripts:

```powershell
<powershell>
New-Item -ItemType Directory -Path "C:\Scripts" -Force | Out-Null

$bytes = [Convert]::FromBase64String("${script_content}")
[System.IO.File]::WriteAllBytes("C:\Scripts\Install-WinGetAndPowerShell7.ps1", $bytes)

$bytes2 = [Convert]::FromBase64String("${steamcmd_script}")
[System.IO.File]::WriteAllBytes("C:\Scripts\Install-SteamPSandSteamCMD.ps1", $bytes2)

</powershell>
```

On first boot, this creates `C:\Scripts` and writes the two scripts into it. It doesn't run them. You'll do that in the server setup section. The `${...}` values are the placeholders `templatefile` fills in.

**`Install-WinGetAndPowerShell7.ps1`** installs WinGet, then uses it to install PowerShell 7:

```powershell
# Install the required package provider and client module
Install-PackageProvider -Name NuGet -Force
Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery

# Use the repair cmdlet to download and install the WinGet client and dependencies
Repair-WinGetPackageManager -AllUsers

# Install Powershell 7 using winget
winget install Microsoft.PowerShell --source winget
```

**`Install-SteamPSandSteamCMD.ps1`** installs the SteamPS module, then SteamCMD, the command-line tool that downloads the Palworld server files:

```powershell
Install-Module -Name SteamPS -Force -AllowClobber
Install-SteamCMD -InstallPath "C:\SteamCMD"
```

### Outputs

```hcl
output "pworld_lab_instance_id" {
  value = aws_instance.pworld_lab_instance.id
}

output "pworld_lab_instance_public_ip" {
  value = aws_instance.pworld_lab_instance.public_ip
}
```

After `apply`, Terraform prints these two values. The **instance ID** helps you find the server in the console to grab the RDP file and decrypt the password. The **public IP** is what you'll connect to over RDP and enter in Palworld to join.

---

## Deploy the infrastructure

From the project folder in the VS Code terminal, run:

```powershell
terraform apply
```

Terraform shows the same plan as before and asks for confirmation. Type `yes`. After a minute or two, it prints the instance ID and public IP.

Give the instance a few more minutes after that. It needs time to boot and run the bootstrap script, and AWS won't have the Windows password ready for about 5 minutes after launch.

---

## Configure the Palworld server

Terraform built the server, but Palworld isn't installed yet. That part is done by hand on the instance.

### 1. Connect over RDP

1. In the AWS console, go to **EC2 → Instances**, select `pworld_lab_instance`, and click **Connect**.
2. On the **RDP client** tab, download the remote desktop file.
3. Click **Get password**, upload your `pworld_kp` private key (`.pem`), and decrypt the password.
4. Open the RDP file, log in as `Administrator` with the decrypted password.

### 2. Install PowerShell 7

Open **Windows PowerShell as administrator** and run:

```powershell
cd C:\Scripts
.\Install-WinGetAndPowerShell7.ps1
```

### 3. Install SteamPS and SteamCMD

Open **PowerShell 7 as administrator** and run:

```powershell
cd C:\Scripts
.\Install-SteamPSandSteamCMD.ps1
```

### 4. Install the Palworld server

Close PowerShell, then open **PowerShell 7 as administrator** again so it picks up the new SteamCMD install. Run:

```powershell
steamcmd +login anonymous +app_update 2394010 validate +quit
```

`2394010` is the Steam app ID for the Palworld dedicated server. This sometimes fails the first time, so if it does, just run it again.

When it finishes, move to the server directory:

```powershell
cd C:\SteamCMD\SteamCMD\steamapps\common\PalServer
```

### 5. Install the DirectX runtime

The server needs the DirectX End-User Runtime from Microsoft. Windows Server's Internet Explorer Enhanced Security Configuration blocks the download page, so turn it off first:

**Server Manager → Local Server → IE Enhanced Security Configuration → Off**

Then download and run the DirectX End-User Runtime installer from Microsoft's site.

### 6. Open the Windows firewall ports

The security group we built in Terraform is one firewall, and Windows has its own. Both have to allow the traffic. Open the Palworld ports in PowerShell:

```powershell
New-NetFirewallRule -DisplayName "Palworld Game" -Direction Inbound -Protocol UDP -LocalPort 8211 -Action Allow
New-NetFirewallRule -DisplayName "Palworld API" -Direction Inbound -Protocol TCP -LocalPort 8212 -Action Allow
```

You can also add these as inbound rules in **Windows Defender Firewall with Advanced Security**. The result is the same.

### 7. Start the server

From the `PalServer` directory, run:

```powershell
.\PalServer.exe
```

Leave the window open. Closing it stops the server.

### 8. Join from the game

Launch Palworld on your local machine, choose the option for joining a dedicated server, and enter:

```
<instance public IP>:8211
```

The public IP is in the Terraform output, or in the EC2 console. Remember that only the IP you ran Terraform from is allowed through the security group, so connect from the same network.

---

## Tear it down

The instance bills for as long as it exists, so when you're done terrorizing the good people of Palworld, go ahead and run:

```powershell
terraform destroy
```

Review the list and type `yes`. This deletes the instance, its disk, and the security group.

> **Run it from the same folder you ran `apply` in.** That folder holds Terraform's state file, which is how it knows what it built. If the folder is deleted, or you extract the ZIP somewhere else, Terraform won't know about the instance, and you'll have to delete the instance and security group by hand in the EC2 console.

Terraform didn't create the `pworld_kp` key pair or your access key, so it won't remove them. Delete both in the AWS console if you're finished with the lab. Finally, check **EC2 → Instances** to confirm the instance shows as terminated.
