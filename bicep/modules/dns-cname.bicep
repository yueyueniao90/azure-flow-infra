// One CNAME record set in the shared DNS zone; deployed into the shared resource group.
// main.bicep uses it to point a stage's webHost at its Static Web App. The custom-domain binding only proves
// ownership (the `_dnsauth` TXT record); this record is what makes the hostname resolve to the site.

param zoneName string

@description('Record-set name relative to the zone, e.g. "staging" for staging.demo.zzll.de.')
param recordName string

@description('Hostname the record points at, e.g. the Static Web App\'s defaultHostname.')
param target string

resource zone 'Microsoft.Network/dnsZones@2018-05-01' existing = {
  name: zoneName
}

resource record 'Microsoft.Network/dnsZones/CNAME@2018-05-01' = {
  parent: zone
  name: recordName
  properties: {
    TTL: 3600
    CNAMERecord: {
      cname: target
    }
  }
}

output fqdn string = record.properties.fqdn
