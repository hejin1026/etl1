{application, etl1,
 [{description, "etl1"},
  {vsn, "1.0.0"},
  {modules, [etl1,
             etl1_app,
             etl1_sup,
             etl1_agent,
             etl1_mpd,
             etl1_tcp
            ]},
  {registered, []},
  {applications, [kernel, stdlib]},
  {env, []},
  {mod, {etl1_app, []}}]}.