┌─────────────────────────────────────────────────────────────┐
│              MASTER CONTROL DASHBOARD (Browser)             					│
│  (Your Human-in-the-Loop Interface)                         					│
├─────────────────────────────────────────────────────────────┤
│                                                              					│
│  ┌─────────────────────────────────────────────────────┐     │
│  │  QUERY INPUT                                        				 │     │
│  │  ┌─────────────────────────────────────────────┐     │      │
│  │  │ SELECT * FROM pcde_procedure_registry...    			   │     │     │
│  │  └─────────────────────────────────────────────┘     │     │
│  │  [Database: pcde_memory] [Execute via CVI] 						 │   │
│  └─────────────────────────────────────────────────────┘   │
│                            ↓                                				  │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  RESULTS (JSON formatted, human readable)           				 │    │
│  │                                                    				 │    │
│  │  {                                                  				 │    │
│  │    "procedure_id": 83,                              				│     │
│  │    "procedure_name": "Series Details Pipeline",    				 │    │
│  │    "domain": "ingest",                              				 │    │
│  │    "description": "Provider ingestion pipeline..."  				 │    │
│  │  }                                                   				 │   │
│  └─────────────────────────────────────────────────────┘   │
│                            ↓                              				  │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  QUICK ACTIONS                                      				 │   │
│  │  [Check Governance] [Run Procedure] [Store Learning] 				 │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────┐
│                    CVI GATEWAY (dog_open.php)               					 │
│  "The single point of access for ALL database operations"   					 │
├─────────────────────────────────────────────────────────────┤
│  POST /_workers/api/series/dog_open.php                     					 │
│  {                                                            				 │
│    "token": "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY",              					 │
│    "db": "xpdgxfsp_pcde_memory",                             					 │
│    "sql": "SELECT * FROM pcde_procedure_registry LIMIT 10",   				 │
│    "params": []                                               				 │
│  }                                                               				 │
└─────────────────────────────────────────────────────────────┘