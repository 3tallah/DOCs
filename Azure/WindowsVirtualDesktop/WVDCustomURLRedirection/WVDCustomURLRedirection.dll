using static System.Environment;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
public static async Task<HttpResponseMessage> Run (HttpRequestMessage req, TraceWriter log) {
string OriginUrl = req.Headers.GetValues ("DISGUISED-HOST").FirstOrDefault ();
log.Info ("RequestURI org: " + OriginUrl);
//create response
var response = req.CreateResponse (HttpStatusCode.MovedPermanently);
if (OriginUrl.Contains ("wvd.haitex.it")) {
response.Headers.Location = new Uri ("https://rdweb.wvd.microsoft.com/arm/webclient");
} else {
log.Info ("error RequestURI org: " + OriginUrl);
return req.CreateResponse (HttpStatusCode.InternalServerError);
}
return response;
}
