provider "aws" {
  region = "us-east-2"
}

#use default VPC
data "aws_vpc" "default" {
  default = true
}

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

output "pworld_lab_instance_id" {
  value = aws_instance.pworld_lab_instance.id
}

output "pworld_lab_instance_public_ip" {
  value = aws_instance.pworld_lab_instance.public_ip
}

