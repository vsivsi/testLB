lbJobs = new JobCollection 'lbJobs'

if Meteor.isClient

  Meteor.subscribe 'sortedJobs'

  date = new ReactiveVar new Date()

  updateDate = () ->
    date.set new Date

  Meteor.setInterval updateDate, 5000

  Template.dataTable.helpers

    dataEntries: () ->
      return lbJobs.find { type: @worker }, { sort: { "result.timestamp": -1 }, limit: 5 }

    timeStamp: () ->
      date.get()
      moment(this.result.timestamp).format("dddd, MMMM Do YYYY, h:mm:ss a")

  Meteor.startup () ->

    Meteor.subscribe 'sortedJobs', () ->
      chartData = lbJobs.find({ type: 'getData' }, { sort: { "result.timestamp": 1 }, limit: 60 }).map((d) -> d.result)
      chartData2 = lbJobs.find({ type: 'getData2' }, { sort: { "result.timestamp": 1 }, limit: 60 }).map((d) -> d.result)

      lineChart = window.c3.generate(
        bindto: '#chart'
        data:
          json: chartData
          keys:
            value: ['timestamp', 'percent']
          x: 'timestamp'
        axis:
          y:
            min: 0
            max: 100
            padding:
              top: 0
              bottom: 0
            label:
              text: 'Percent'
              position: 'outer-middle'
          x:
            label:
              text: 'Time'
              position: 'outer-center'
            type: 'timeseries',
            tick:
              format: '%H:%M:%S'
      )

      Tracker.autorun () ->
        chartData = lbJobs.find({}, { sort: { "result.timestamp": -1 }, limit: 1 }).map((d) -> d.result)
        lineChart.flow
          json: chartData2
          keys:
            value: ['timestamp', 'percent']
          x: 'timestamp'
          length: Math.max 0, lineChart.x().percent.length - 59

if Meteor.isServer

  lbJobs._ensureIndex { "result.timestamp": 1 }

  Meteor.publish 'sortedJobs', () ->
    return lbJobs.find { status: 'completed' }, { sort: { "result.timestamp": -1 }, limit: 60 }

  request = Meteor.npmRequire 'request'
  es = Meteor.npmRequire 'event-stream'

  Meteor.startup () ->

    lbJobs.promote 1000

    lbJobs.setLogStream process.stdout

    job = new Job(lbJobs, 'getData',
      dev: process.env["LITTLEBIT_DEV1_ID"]
    )
    .retry({ retries: 8, wait: 1000, backoff: 'exponential' })
    .repeat({ wait: 1*60*1000 })
    .save({cancelRepeats: true})

    job2 = new Job(lbJobs, 'getData2',
      dev: process.env["LITTLEBIT_DEV2_ID"]
    )
    .retry({ retries: 8, wait: 1000, backoff: 'exponential' })
    .repeat({ wait: 1*60*1000 })
    .save({cancelRepeats: true})

    # code to run on server at startup

    lbJobs.startJobServer()

    q = lbJobs.processJobs ['getData','getData2'], { pollInterval: 500000000 }, (j, cb) ->

      bind_env = (func) ->
        if func?
           return Meteor.bindEnvironment func, (err) -> throw err
        else
           return func

      finishJob = bind_env (err, val) ->
        if err
          j.fail { error: "#{err}" }
        else
          j.done val
        cb()

      authToken = process.env["LITTLEBIT_AUTH_TOKEN"]
      deviceId = j.data.dev

      reqOptions =
        url: "https://api-http.littlebitscloud.cc/v3/devices/#{deviceId}/input"
        headers:
          "Authorization": "Bearer #{authToken}"

      reqStream = request(reqOptions)
      reqStream.on('error', (err) ->
            console.error "Error: ", err
            finishJob err
            reqStream.abort()
         )
         .on('response', (res) ->
            console.warn "Response status:", res.statusCode
            if res.statusCode isnt 200
              console.warn "Response status:", res.statusCode
              finishJob new Error "Bad HTTP response (#{res.statusCode})"
              reqStream.abort()
         )
         .pipe(es.split())
         .pipe(es.map (data, cb)->
            if data
               cb(null, data.substr(5))
            else
               cb()
         )
         .pipe(es.parse())
         .pipe(es.map (data, cb)->
            if data and data.percent?
              cb(null, "#{data.percent}%\n")
              finishJob null, { timestamp: data.timestamp, percent: data.percent }
            else
              finishJob new Error "Missing data value"
              cb()
            reqStream.abort()
         )
         # .pipe(process.stdout)

    lbJobs.find({ type: 'getData', status: 'ready' })
      .observe({ added: () -> q.trigger() })
