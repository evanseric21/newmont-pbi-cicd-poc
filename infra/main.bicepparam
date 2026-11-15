using './main.bicep'

param prefix = 'newmont-poc'
param allowedClientCidr = '0.0.0.0/32' // TODO: replace with your public IP, e.g. 203.0.113.10/32
param sqlAdminPassword = readEnvironmentVariable('POC_SQL_ADMIN_PASSWORD')
param vmAdminPassword = readEnvironmentVariable('POC_VM_ADMIN_PASSWORD')
