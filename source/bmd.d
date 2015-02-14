#!/usr/bin/env rdmd

import std.conv;
import std.json;
import std.stdio;
import std.getopt;
import std.algorithm;
import tinyredis.redis;
import painlessjson;

const string VERSION = "0.0.1";
const string HELP    =
"Simple command line browser independant bookmark utility.

Usage: bm [options] [-r] URL TAG...
       bm [options]  -d  URL
       bm [options]  -l  [TAG]...
       bm [options]  URL

Arguments:
    URL     The url to bookmark
            If alone, print the tags associated with URL
            If the url corresponds to an existing file,
            the absolute path is substituted to URL
            If URL is '-', then the program looks for a list of URL
            comming from the standard input.
    TAG     The tags to use with the url.

Options:
    -h, --help          Print this help and exit
    --version           Print current version number

    -r, --remove        Remove TAG from URL
    -d, --delete        Delete an url from the database
    -l, --list-every    List the urls with every of TAG";


alias db_t = string[][string];


class Database
{
    Redis  redis;
    string redisID;
    db_t   data;

    this(string redisID, string rHost="127.0.0.1", ushort rPort=6379) {
        this.redisID = redisID;
        this.redis   = new Redis(rHost, rPort);
    }

    /***** Operator overloading to transfer access to this.data ******/

    string[] opIndex(string idx)
    {
        return data[idx];
    }

    void opIndexAssign(string[] value, string idx)
    {
        data[idx] = value;
    }

    string[]* opBinaryRight(string op)(string value)
    {
        if (op == "in")
            return value in data;
    }

    /***** Redis interface *****/

    void getData() {
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


    void setData() {
        redis.send("SET", redisID, data.toJSON);
    }

    /***** Data management *****/

    void urlDelete(string url) {
        if (url in data)
            data.remove(url);
    }

    void tagAdd(string url, string tag) {
        if (tag) {
            if (url !in data)
                data[url] = [];
            data[url] ~= canFind(data[url], tag) ? cast(string[])[] : [tag];
        }
    }

    void tagRemove(string url, string tag) {
        data[url] = data[url].splitter(tag).join();

        if (data[url].length == 0)
            this.urlDelete(url);
    }

    void tagsPrint(string url) {
        if (url in data)
            foreach(tag ; data[url])
                writeln(tag);
    }

    string[] listEvery(string[] tags) {
        string[] result = [];
        foreach (tag ; tags) {
            foreach(url, utag ; data)
                if (utag.canFind(tag))
                    result ~= url;
        }
        return result;
    }
}


int main(string[] args)
{
    bool optRemove    = false;
    bool optDelete    = false;
    bool optListAny   = false;
    bool optListEvery = false;
    auto ID           = "BMD_DATA";

    if (args.length == 1) {
        writeln(HELP);
        return 1;
    }

    getopt(args,
            "h|help",       { writeln(HELP); },
            "version",      { writeln("Version: " ~ VERSION); },
            "r|remove",     &optRemove,
            "l|list-every", &optListEvery,
            "d|delete",     &optDelete
          );

    auto url   = args.length>1 ? args[1]    : null;
    auto tags  = args.length>1 ? args[2..$] : null;

    auto db = new Database(ID);
    db.getData();

    debug writeln("* Original db: " ~ db.to!string);

    if (url in db && optDelete) {
        db.urlDelete(url);
    }
    else if (optRemove && url in db && tags.length != 0) {
        foreach(tag ; tags)
            db.tagRemove(url, tag);
    }
    else if (optListEvery) {
        if (!url) {
            foreach (u, t ; db.data)
                writeln(u);
        }
        else {
            tags = url ~ tags;
            foreach (elem ; db.listEvery(tags))
                writeln(elem);
        }
    }
    else if (tags.length != 0) {
        foreach(tag ; tags)
            db.tagAdd(url, tag);
    }
    else if (url in db) {
        db.tagsPrint(url);
    }

    debug writeln("* Final db: " ~ db.to!string);

    db.setData();
    return 0;
}
