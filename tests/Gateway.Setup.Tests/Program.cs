using System.Diagnostics;
using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Gateway.Setup.Security;

static void Check(bool condition,string message) { if(!condition) throw new Exception(message); }
var issue=SessionNonceGate.Create();
Check(!issue.Gate.TryConsume("wrong"),"Invalid nonce was accepted.");
Check(issue.Gate.TryConsume(issue.Nonce),"Valid nonce was rejected.");
Check(!issue.Gate.TryConsume(issue.Nonce),"Nonce replay was accepted.");
Check(SetupSessionPolicy.Evaluate(false,"POST","/setup",issue.Nonce,issue.Gate)==SessionDecision.Deny,"POST established a session.");

var fixture=Path.Combine(Path.GetTempPath(),"gateway-setup-test-"+Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(Path.Combine(fixture,"bootstrap"));
Directory.CreateDirectory(Path.Combine(fixture,"web","setup","dist"));
await File.WriteAllTextAsync(Path.Combine(fixture,"Gateway.slnx"),"<Solution />");
await File.WriteAllTextAsync(Path.Combine(fixture,"bootstrap","bootstrap.ps1"),"throw 'Provisioning must never execute in this test.'");
await File.WriteAllTextAsync(Path.Combine(fixture,"bootstrap","setup-bridge.ps1"),"param($Action)\n[Console]::Out.WriteLine('{\"type\":\"Setup\",\"data\":{\"fixture\":true}}')");
await File.WriteAllTextAsync(Path.Combine(fixture,"web","setup","dist","index.html"),"<html>Setup fixture</html>");
var start=new ProcessStartInfo("dotnet") {UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true};
foreach(var arg in new[]{typeof(SessionNonceGate).Assembly.Location,"--repo-root",fixture,"--no-open"}) start.ArgumentList.Add(arg);
using var child=Process.Start(start)!;
using var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(45));
var errors=child.StandardError.ReadToEndAsync(timeout.Token);
try {
    Uri? link=null;
    while(link is null) {
        var line=await child.StandardOutput.ReadLineAsync(timeout.Token);
        if(line is null) throw new Exception("Setup exited before listening: "+await errors);
        var match=System.Text.RegularExpressions.Regex.Match(line,@"http://127\.0\.0\.1:\d+/setup\?nonce=[A-Za-z0-9_-]+");
        if(match.Success) link=new Uri(match.Value);
    }
    using var http=new HttpClient(new HttpClientHandler {CookieContainer=new CookieContainer(),AllowAutoRedirect=true}) {BaseAddress=new Uri(link.GetLeftPart(UriPartial.Authority))};
    Check((await http.GetAsync("/api/setup/progress")).StatusCode==HttpStatusCode.NotFound,"Anonymous API access was accepted.");
    Check((await http.GetAsync(link)).IsSuccessStatusCode,"Nonce handshake failed.");
    var noCsrf=await http.PostAsJsonAsync("/api/setup/operations",new{action="Inspect"});
    Check(noCsrf.StatusCode==HttpStatusCode.BadRequest,"Missing CSRF token was accepted.");
    var session=await http.GetFromJsonAsync<JsonElement>("/api/setup/session");
    http.DefaultRequestHeaders.Add("X-Setup-Csrf",session.GetProperty("token").GetString());
    using var arbitraryBody=new StringContent("{\"action\":\"Destroy\"}",System.Text.Encoding.UTF8,"application/json");
    var arbitrary=await http.PostAsync("/api/setup/operations",arbitraryBody);
    Check(arbitrary.StatusCode==HttpStatusCode.BadRequest && (await arbitrary.Content.ReadAsStringAsync()).Contains("Unsupported setup action"),"Command admission was not exercised.");
    using var applyBody=new StringContent(JsonSerializer.Serialize(new{action="Apply",fingerprint="sha256:"+new string('0',64)}),System.Text.Encoding.UTF8,"application/json");
    var apply=await http.PostAsync("/api/setup/operations",applyBody);
    Check(apply.StatusCode==HttpStatusCode.BadRequest && (await apply.Content.ReadAsStringAsync()).Contains("Review the current plan"),"Unreviewed Apply was accepted or not checked.");
    // Supply a known length as browser fetch does; HttpClient JSON uses chunked encoding by default.
    using var inspect=new StringContent("{\"action\":\"Inspect\"}",System.Text.Encoding.UTF8,"application/json");
    Check((await http.PostAsync("/api/setup/operations",inspect)).StatusCode==HttpStatusCode.Accepted,"Inspect was not dispatched.");
    JsonElement progress;
    do {await Task.Delay(200,timeout.Token);progress=await http.GetFromJsonAsync<JsonElement>("/api/setup/progress",timeout.Token);} while(progress.GetProperty("running").GetBoolean());
    Check(progress.GetProperty("exitCode").GetInt32()==0,"Shared bridge process failed.");
    Check(progress.GetProperty("events")[0].GetProperty("data").GetProperty("fixture").GetBoolean(),"Typed bridge result was lost.");
    using var anonymous=new HttpClient();
    Check((await anonymous.GetAsync(link)).StatusCode==HttpStatusCode.NotFound,"Consumed link established another session.");
    Console.WriteLine("Setup host passed nonce/session isolation, CSRF, command admission, unreviewed Apply rejection and bridge execution tests.");
} finally {
    if(!child.HasExited) child.Kill(true);
    await child.WaitForExitAsync();
    if(Path.GetDirectoryName(fixture)==Path.GetTempPath().TrimEnd(Path.DirectorySeparatorChar) && Path.GetFileName(fixture).StartsWith("gateway-setup-test-",StringComparison.Ordinal)) Directory.Delete(fixture,true);
}
