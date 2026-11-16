// Newmont CI/CD POC - Azure infrastructure
//   * Azure SQL logical server + two databases that simulate the Databricks catalogs:
//       newmont_test -> Dev / QA (Databricks test)    newmont_prod -> Prod (Databricks production)
//   * Windows Server VM hosting the GitHub self-hosted runner AND the on-premises data gateway
//
// Deploy:
//   az group create -n rg-newmont-pbi-poc -l eastus2
//   az deployment group create -g rg-newmont-pbi-poc -f infra/main.bicep -p infra/main.bicepparam

targetScope = 'resourceGroup'

@description('Prefix for all resource names.')
param prefix string = 'newmont-poc'

param location string = resourceGroup().location

@description('SQL administrator login.')
param sqlAdminLogin string = 'sqladminpoc'

@secure()
@description('SQL administrator password.')
param sqlAdminPassword string

@description('VM local administrator username.')
param vmAdminUsername string = 'pocadmin'

@secure()
@description('VM local administrator password.')
param vmAdminPassword string

@description('Public IP/CIDR allowed to RDP to the VM and to reach SQL (your workstation), e.g. 203.0.113.10/32.')
param allowedClientCidr string

@description('VM size for the runner + gateway host.')
param vmSize string = 'Standard_D4s_v5'

@description('Daily auto-shutdown time (HHmm, UTC) to save cost. Empty string disables it.')
param autoShutdownTimeUtc string = '0200'

var suffix = take(uniqueString(resourceGroup().id), 6)
var sqlServerName = '${prefix}-sql-${suffix}'
var vmName = take('nmpocrunner${suffix}', 15)

// ---------- Azure SQL ----------
resource sql 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: sqlServerName
  location: location
  properties: {
    administratorLogin: sqlAdminLogin
    administratorLoginPassword: sqlAdminPassword
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
  }
}

@description('Dev/QA database (Databricks test catalog) and Prod database (Databricks production catalog).')
param sqlDatabaseNames object = {
  test: 'newmont_test'
  prod: 'newmont_prod'
}

resource dbTest 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  parent: sql
  name: sqlDatabaseNames.test
  location: location
  sku: {
    name: 'Basic'
    tier: 'Basic'
  }
}

resource dbProd 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  parent: sql
  name: sqlDatabaseNames.prod
  location: location
  sku: {
    name: 'Basic'
    tier: 'Basic'
  }
}

// Lets the VM (gateway + runner) reach SQL. Lock down with VNet rules/private endpoint in a real build.
resource fwAzure 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = {
  parent: sql
  name: 'AllowAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

resource fwClient 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = {
  parent: sql
  name: 'AllowClient'
  properties: {
    startIpAddress: parseCidr(allowedClientCidr).firstUsable
    endIpAddress: parseCidr(allowedClientCidr).lastUsable
  }
}

// ---------- Network ----------
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: '${prefix}-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowRdpFromClient'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: allowedClientCidr
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: '${prefix}-vnet'
  location: location
  properties: {
    addressSpace: { addressPrefixes: [ '10.40.0.0/24' ] }
    subnets: [
      {
        name: 'runner'
        properties: {
          addressPrefix: '10.40.0.0/26'
          networkSecurityGroup: { id: nsg.id }
        }
      }
    ]
  }
}

resource pip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: '${prefix}-runner-pip'
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: '${prefix}-runner-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: vnet.properties.subnets[0].id }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: { id: pip.id }
        }
      }
    ]
  }
}

// ---------- VM: self-hosted runner + on-premises data gateway ----------
resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: vmName
  location: location
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: vmName
      adminUsername: vmAdminUsername
      adminPassword: vmAdminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        provisionVMAgent: true
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-azure-edition'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'Premium_LRS' }
      }
    }
    networkProfile: {
      networkInterfaces: [ { id: nic.id } ]
    }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
  }
}

resource shutdown 'Microsoft.DevTestLab/schedules@2018-09-15' = if (!empty(autoShutdownTimeUtc)) {
  name: 'shutdown-computevm-${vmName}'
  location: location
  properties: {
    status: 'Enabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: { time: autoShutdownTimeUtc }
    timeZoneId: 'UTC'
    targetResourceId: vm.id
  }
}

output sqlServerFqdn string = sql.properties.fullyQualifiedDomainName
output sqlTestDatabase string = dbTest.name
output sqlProdDatabase string = dbProd.name
output vmName string = vm.name
output vmPublicIp string = pip.properties.ipAddress
