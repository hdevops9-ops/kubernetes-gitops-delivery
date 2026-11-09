"""Fail on medium/high passive DAST findings; never treat an empty report as proof."""
import json
import sys

def check(report):
    sites=report.get('site',[])
    if not sites: raise ValueError('DAST report contains no scanned sites')
    blocked=[]
    total=0
    for site in sites:
        for alert in site.get('alerts',[]):
            total+=1
            rule=str(alert.get('pluginid',''))
            # This exception is only for the explicit loopback HTTP integration target.
            internal_http=(site.get('@name')=='http://127.0.0.1:8088')
            if rule=='10035' and internal_http: continue
            if int(alert['riskcode'])>=2:
                blocked.append({'rule':rule,'name':alert.get('name',alert.get('alert','unknown'))})
    if blocked: raise ValueError('Blocking DAST findings: '+json.dumps(blocked))
    return {'scanned_sites':len(sites),'total_alerts':total,'blocking_medium_high_alerts':0}

if __name__=='__main__':
    try:
        with open(sys.argv[1]) as f:print(json.dumps(check(json.load(f))))
    except (ValueError,KeyError,OSError) as e:sys.exit(str(e))
