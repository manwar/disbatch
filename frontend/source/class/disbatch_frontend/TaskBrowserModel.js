qx.Class.define("disbatch_frontend.TaskBrowserModel",
{
  extend : qx.ui.table.model.Remote,

  members :
  {
    setQueueID : function( qid )
    {
      this.queue = qid;
    },

     // overloaded - called whenever the table requests the row count
    _loadRowCount : function()
    {
      // Call the backend service (example) - using XmlHttp
      var url  = "/search-tasks-json";
      var req = new qx.io.remote.Request(url, "GET", "application/json");
      req.setParameter( "queue", this.queue );
      req.setParameter( "json", 1 );
      req.setParameter( "filter", this.constructFilter() );
      req.setParameter( "count", 1 );

      // Add listener
      req.addListener("completed", this._onRowCountCompleted, this);

      // send request
      req.send();
    },

    // Listener for request of "_loadRowCount" method
    _onRowCountCompleted : function(response)
    {
       var result = response.getContent();
       if (result != null)
       {
          // Apply it to the model - the method "_onRowCountLoaded" has to be called
          this._onRowCountLoaded(result[1]);
       }
    },


    // overloaded - called whenever the table requests new data
    _loadRowData : function(firstRow, lastRow)
    {
      var url  = "/search-tasks-json";
      var req = new qx.io.remote.Request(url, "GET", "application/json");
      req.setParameter( "queue", this.queue );
      req.setParameter( "json", 1 );
      req.setParameter( "filter", this.constructFilter() );
      req.setParameter( "skip", firstRow );
      req.setParameter( "limit", lastRow - firstRow + 1 );
      req.setParameter( "terse", 1 );
      req.addListener( "completed", this._onLoadRowDataCompleted, this );
      req.send();
    },

     // Listener for request of "_loadRowData" method
    _onLoadRowDataCompleted : function(response)
    {
        var result = response.getContent();
       if (result != null)
       {
          // Apply it to the model - the method "_onRowDataLoaded" has to be called
          for ( var x in result )
          {
            var r = result[ x ];
            if ( r["parameters"] )
            {
              var parameters = "";
              for ( var y in r["parameters"] )
              {
                if ( typeof(r["parameters"][y]) == "string" )
                  parameters += r["parameters"][y] + " ";
              }
              r["parameters"] = parameters;

//              alert( r["_id"]["$oid"] );
              var realId = r["_id"]["$oid"];
              r["_id"] = realId;
            }
          }

          this._onRowDataLoaded(result);
       }
       else
       {
        alert ("w t f" );
       }
    },

    constructFilter : function()
    {
      if ( !this.filter )
      {
        this.filter = new Object;
      }
      return qx.lang.Json.stringify( this.filter );
    }

  }
});