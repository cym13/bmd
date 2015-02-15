#!/usr/bin/env rdmd

import std.conv;
import std.json;
import std.stdio;
import std.array;
import std.getopt;
import std.process;
import std.c.stdlib;
import std.algorithm;
import tinyredis.redis;
import painlessjson;

immutable string VERSION = "1.0.0";
immutable string HELP    =
"Simple command line browser independant bookmark utility.

Usage: bmd [options] [-r] URL TAG...
       bmd [options]  -d  URL
       bmd [options]  -l  [TAG]...
       bmd [options]  -L  [TAG]...
       bmd [options]  URL

Arguments:
    URL     The url to bookmark
            If alone, print the tags associated with URL
            If the url corresponds to an existing file,
            the absolute path is substituted to URL
            If URL is '-', then the program looks for a list of URL
            comming from the standard input.
    TAG     The tags to use with the url.

Options:
    -h, --help                   Print this help and exit
    --version                    Print current version number

    -r, --remove                 Remove TAG from URL
    -d, --delete                 Delete an url from the database
    -l, --list-every             List the urls with every of TAG
    -L, --list-any               List the urls with any of TAG

    -n, --no-path-subs           Disable file path substitution
    -I, --redis-ID ID            Redis variable ID to be used
                                 Default is BMD_DATA
    -R, --redis-serveur IP:PORT  Which redis server to connect to
                                 Default to 127.0.0.1:6379
    -w, --web                    Open the results in a web browser
";


class Database
{
    Redis            redis;
    string           redisID;
    string[][string] data;

    this(const string redisID,
         const string rHost="127.0.0.1",
         const ushort rPort=6379)
    {
        this.redisID = redisID;
        this.redis   = new Redis(rHost, rPort);
    }

    /***** Operator overloading to transfer access to this.data ******/

    @safe
    string[] opIndex(string idx)
    {
        return data[idx];
    }

    @safe
    void opIndexAssign(string[] value, const string idx)
    {
        data[idx] = value;
    }

    @safe
    pure
    string[]* opBinaryRight(string op)(const string value)
    {
        if (op == "in")
            return value in data;
    }

    /***** Redis interface *****/

    void getData()
    {
        string raw;

        if (!redis.send("EXISTS", redisID)) {
            redis.send("SET", redisID, "{}");
            raw = "{}";
        }
        else {
            raw = redis.send("GET", redisID).to!string;
        }

        debug writeln("* getData: " ~ raw);
        foreach(string url, JSONValue tags ; raw.parseJSON.object) {
            foreach(JSONValue tag ; tags.array) {
                data[url] ~= tag.str;
            }
        }
    }

    void setData()
    {
        redis.send("SET", redisID, data.toJSON);
    }

    /***** Data management *****/

    @safe
    void urlDelete(const string url)
    {
        if (url in data)
            data.remove(url);
    }

    @safe
    void tagAdd(const string url, const string tag)
    {
        if (tag) {
            if (url !in data)
                data[url] = [];
            data[url] ~= canFind(data[url], tag) ? [] : [tag];
        }
    }

    @safe
    void tagRemove(const string url, const string tag)
    {
        data[url] = data[url].splitter(tag).join();

        if (data[url].length == 0)
            this.urlDelete(url);
    }

    @safe
    pure
    string[] listAny(const string[] tags)
    {
        string[] result = [];
        foreach (tag ; tags) {
            foreach(url, utag ; data)
                if (utag.canFind(tag))
                    result ~= url;
        }
        return result;
    }

    @safe
    pure
    string[] listEvery(const string[] tags)
    {
        string[] result = [];
        foreach (url, utag ; data) {
            bool canAdd = true;
            foreach (tag ; tags)
                if (!utag.canFind(tag))
                    canAdd = false;

            if (canAdd)
                result ~= url;
        }
        return result;
    }


    string[] manageArgs(string[] args)
    {
        auto pArgs = parseArgs(args);
        auto flag  = pArgs["flag"][0];
        auto urls  = pArgs["urls"];
        auto tags  = pArgs["tags"];

        string[] result = [];

        if (flag == "delete") {
            foreach (url ; urls)
                try
                    urlDelete(url);
                catch (core.exception.RangeError)
                    continue;
        }

        else if (flag == "remove") {
            foreach (url ; urls)
                foreach (tag ; tags)
                    try
                        tagRemove(url, tag);
                    catch (core.exception.RangeError)
                        continue;
        }

        else if (flag == "listAny" || flag == "listEvery") {
            string[] delegate(const string[] tag) listFunction;

            if (tags.empty)
                listFunction = (x => cast(string[])data.keys);
            else if (flag == "listEvery")
                listFunction = &listEvery;
            else if (flag == "listAny")
                listFunction = &listAny;

            foreach (url ; listFunction(tags))
                result ~= url;
        }

        else if (flag == "assign") {
            foreach (url ; urls)
                foreach (tag ; tags)
                    tagAdd(url, tag);
        }

        else if (flag == "get") {
            foreach (url ; urls)
                if (url in data)
                    result ~= data[url];
        }


        if (pArgs["flag"].canFind("web")) {
            webOpen(environment.get("BROWSER", "firefox"),
                    htmlGenerator(tags, result));
        }
        else {
            foreach (element ; result)
                writeln(element);
        }

        return result;
    }
}


string[][string] parseArgs(string[] args)
{
    string[][string] result;

    bool optRemove    = false;
    bool optDelete    = false;
    bool optListAny   = false;
    bool optListEvery = false;
    bool optNoPathSub = false;
    bool optWebOpen   = false;

    getopt(args,
            "r|remove",       &optRemove,
            "l|list-every",   &optListEvery,
            "L|list-any",     &optListAny,
            "d|delete",       &optDelete,
            "n|no-path-subs", &optNoPathSub,
            "w|web",          &optWebOpen,
          );

    if (optDelete) {
        result["flag"] = ["delete"];
        result["urls"] = [args[1]];
        result["tags"] = [];
    }
    else if (optRemove) {
        result["flag"] = ["remove"];
        result["urls"] = [args[1]];
        result["tags"] = args[2..$];
    }
    else if (optListAny || optListEvery) {
        result["flag"] = optListEvery ? ["listEvery"] : ["listAny"];
        result["urls"] = [];
        result["tags"] = args.length > 1 ? args[1..$] : [];
    }
    else if (args.length > 2) {
        result["flag"] = ["assign"];
        result["urls"] = [args[1]];
        result["tags"] = args[2..$];
    }
    else if (args.length == 2) {
        result["flag"] = ["get"];
        result["urls"] = [args[1]];
        result["tags"] = [];
    }

    if (optWebOpen)
        result["flag"] ~= "web";

    result["urls"] = expandUrls(result["urls"], !optNoPathSub);

    return result;
}


string[] expandUrls(string[] urls, bool pathSubstitution)
{
    import std.string, std.file, std.path;

    if (urls.canFind("-")) {
        urls = urls.filter!(x => x != "-").array;

        string line;
        while ((line = readln()) !is null)
            urls ~= [line];
        urls = urls.map!chomp.array;
    }

    if (pathSubstitution) {
        for(int i=0 ; i<urls.length ; i++) {
            string url = absolutePath(urls[i]);
            if (url.exists)
                urls[i] = url;
        }
    }

    return urls;
}


@safe
pure
string htmlGenerator(string[] tags, string[] sites)
{
    string liElement = q{<li><a href="%s">%s</a><p>%-(%s, %)</p></li>};

    // Note that here, end of line spaces are meaningfull
    string htmlTemplate  = q{
    <!DOCTYPE html>
    <html>
      <head>
        <meta charset="UTF-8" />
        <title>bookmark</title>
      </head>
      <body>
        <h1>
          %-(%s, %)
        </h1>
        <ol>
          %-(%s          
          %)
        </ol>
      </body>
    </html> };

    string stag  = tags.join(", ");

    string[] slist = [];
    foreach (site ; sites) {
        auto tmpUrl = site.split()[0];
        auto tmpTag = site.split()[1..$];

        slist ~= liElement.format(tmpUrl, tmpUrl, tmpTag);
    }

    return htmlTemplate.format(tags, slist);
}


void webOpen(string browser, string source)
{
    import std.file;

    string htmlFile = "/tmp/bm-tmp.html";

    htmlFile.write(source);
    execute([browser, htmlFile]);
}


int main(string[] args)
{
    bool optHelp   = false;
    auto ID        = "BMD_DATA";
    auto optServer = "127.0.0.1:6379";

    if (args.length == 1) {
        writeln(HELP);
        return 1;
    }

    try {
        getopt(args,
                "h|help",         {writeln(HELP); exit(0);},
                "version",        {writeln("bmd version: "~VERSION); exit(0);},
                "I|redis-ID",     &ID,
                "R|redis-server", &optServer,
              );
    }
    catch (std.getopt.GetOptException) {}

    string host = optServer.findSplit(":")[0];
    ushort port = optServer.findSplit(":")[2].to!ushort;

    auto db = new Database(ID, host, port);
    db.getData();
    db.manageArgs(args);
    db.setData();
    return 0;
}
