# APM Explorer privacy summary

APM Explorer stores only privacy-safe session summaries: start, last-activity and
end times, an aggregate action count, the session timeout, and an end reason.
It also stores UTC hour boundaries with aggregate action counts and the aggregate
amount of time input monitoring was available during each hour. Hourly coverage
distinguishes a monitored zero from partial or unavailable history without
storing individual event timestamps.

The input monitor observes only physical key downs, mouse-button downs, and
scroll-wheel events. It inspects only autorepeat and scroll-phase metadata:
key repeats and scroll momentum are discarded, and scroll input is reduced to
one action per gesture or phase-less burst.

It never stores keys, typed content, pointer locations, application or window
identity, clipboard contents, or individual input events. Activity data stays
on this Mac. Session summaries are retained for 48 hours and hourly aggregates
for a rolling 60 days. Preferences contain only the login-item state, never
activity payloads.
